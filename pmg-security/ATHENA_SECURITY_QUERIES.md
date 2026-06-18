# 🔎 Athena 보안 조사 쿼리 (발표/실무용)

> **목적:** 로그를 "쌓기만" 하는 게 아니라 **실제로 조사·검색할 수 있다**는 것을 증명하는 문서.
> 탐지(GuardDuty/CloudTrail/Flow Logs) → **조사(Athena)** 의 마지막 연결고리.
>
> **비유:** CCTV(CloudTrail)와 출입 번호판 장부(VPC Flow Logs)를 S3 창고에 차곡차곡 쌓아뒀는데,
> 이 문서는 그 장부를 **"누가 언제 우리 음성 금고에 손댔어?"** 같은 질문으로 즉시 검색하는 **돋보기**다.

---

## 0. 사전 준비 (한 번만)

1. **결과 저장은 전용 버킷 + 워크그룹으로 자동 분리** (`athena_results.tf`에서 Terraform으로 생성).
   - 버킷: `s3://securevoice-dev-athena-results-455535733131/` (퍼블릭 차단 + 14일 자동삭제 + 결과 SSE 암호화)
   - **워크그룹 선택만 하면 폴더가 자동 분리됨** (콘솔에서 쿼리 실행 전 우상단 워크그룹 선택):
     - `securevoice-dev-cloudtrail` → 결과가 `cloudtrail/` 폴더로
     - `securevoice-dev-flowlogs` → 결과가 `flowlogs/` 폴더로
   - 워크그룹이 출력 위치를 강제하므로 별도 "쿼리 결과 위치" 설정 불필요.
2. 아래 **CREATE TABLE DDL 2개**를 Athena 쿼리 편집기에 붙여 1회 실행 → 테이블 생성.
   - CloudTrail 테이블 DDL은 `securevoice-dev-cloudtrail` 워크그룹에서, Flow Logs 테이블 DDL은 `securevoice-dev-flowlogs` 워크그룹에서 실행하면 깔끔.
   - **파티션 프로젝션(partition projection)** 을 써서 `MSCK REPAIR`/수동 파티션 추가가 **불필요**.
     날짜 폴더가 새로 생겨도 자동 인식됨.

> 💰 **비용 주의:** Athena는 **스캔한 데이터 1TB당 $5**. 그래서 모든 쿼리는 반드시
> `year='2026' AND month='06' AND day='...'` 같은 **파티션 조건으로 범위를 좁혀** 스캔량(=비용)을 최소화한다.
> parquet 포맷 + 파티션 프로젝션 덕에 실제 스캔은 수 MB 수준 → 사실상 수 센트.

---

## 1. VPC Flow Logs 테이블 (parquet + Hive 파티션)

```sql
CREATE EXTERNAL TABLE IF NOT EXISTS securevoice_vpc_flow_logs (
  version      int,
  account_id   string,
  interface_id string,
  srcaddr      string,   -- 출발지 IP
  dstaddr      string,   -- 목적지 IP
  srcport      int,
  dstport      int,      -- 목적지 포트 (22=SSH, 3306=MySQL 등)
  protocol     bigint,   -- IANA 프로토콜 번호 (6=TCP, 17=UDP)
  packets      bigint,
  bytes        bigint,   -- 전송 바이트 (대량=유출 의심)
  start        bigint,   -- epoch 초
  `end`        bigint,   -- epoch 초 (end는 예약어라 백틱 필요)
  action       string,   -- ACCEPT / REJECT
  log_status   string
)
PARTITIONED BY (year string, month string, day string, hour string)
STORED AS PARQUET
LOCATION 's3://securevoice-dev-vpc-flow-logs-455535733131/AWSLogs/aws-account-id=455535733131/aws-service=vpcflowlogs/aws-region=ap-northeast-2/'
TBLPROPERTIES (
  'projection.enabled'            = 'true',
  'projection.year.type'          = 'integer',
  'projection.year.range'         = '2026,2030',
  'projection.month.type'         = 'integer',
  'projection.month.range'        = '1,12',
  'projection.month.digits'       = '2',
  'projection.day.type'           = 'integer',
  'projection.day.range'          = '1,31',
  'projection.day.digits'         = '2',
  'projection.hour.type'          = 'integer',
  'projection.hour.range'         = '0,23',
  'projection.hour.digits'        = '2',
  'storage.location.template'     = 's3://securevoice-dev-vpc-flow-logs-455535733131/AWSLogs/aws-account-id=455535733131/aws-service=vpcflowlogs/aws-region=ap-northeast-2/year=${year}/month=${month}/day=${day}/hour=${hour}'
);
```

### 🔍 Flow Logs 보안 쿼리

**Q1. 거부된(REJECT) 인바운드 상위 출발지 — 누가 우리 문을 두드리다 막혔나 (스캔·공격 정찰 탐지)**
```sql
SELECT srcaddr, dstport, COUNT(*) AS reject_count
FROM securevoice_vpc_flow_logs
WHERE year='2026' AND month='06'
  AND action='REJECT'
GROUP BY srcaddr, dstport
ORDER BY reject_count DESC
LIMIT 20;
```

**Q2. 민감 포트(SSH 22 / DB 3306) 접근 시도 — 내부 인프라를 직접 노린 흔적**
```sql
SELECT from_unixtime(start) AS ts, srcaddr, dstaddr, dstport, action
FROM securevoice_vpc_flow_logs
WHERE year='2026' AND month='06'
  AND dstport IN (22, 3306)
ORDER BY ts DESC
LIMIT 50;
```

**Q3. 아웃바운드 대량 전송 상위 — 데이터 유출(exfiltration) 의심 탐지**
```sql
SELECT dstaddr, SUM(bytes) AS total_bytes
FROM securevoice_vpc_flow_logs
WHERE year='2026' AND month='06'
  AND action='ACCEPT'
GROUP BY dstaddr
ORDER BY total_bytes DESC
LIMIT 20;
```

---

## 2. CloudTrail 테이블 (표준 JSON + CloudTrailSerde)

```sql
CREATE EXTERNAL TABLE IF NOT EXISTS securevoice_cloudtrail_logs (
  eventversion        STRING,
  useridentity        STRUCT<
    type:STRING, principalid:STRING, arn:STRING, accountid:STRING,
    invokedby:STRING, accesskeyid:STRING, username:STRING,
    sessioncontext:STRUCT<
      attributes:STRUCT<mfaauthenticated:STRING, creationdate:STRING>,
      sessionissuer:STRUCT<type:STRING, principalid:STRING, arn:STRING, accountid:STRING, username:STRING>>>,
  eventtime           STRING,
  eventsource         STRING,
  eventname           STRING,
  awsregion           STRING,
  sourceipaddress     STRING,
  useragent           STRING,
  errorcode           STRING,
  errormessage        STRING,
  requestparameters   STRING,
  responseelements    STRING,
  additionaleventdata STRING,
  requestid           STRING,
  eventid             STRING,
  resources           ARRAY<STRUCT<arn:STRING, accountid:STRING, type:STRING>>,
  eventtype           STRING,
  apiversion          STRING,
  readonly            STRING,
  recipientaccountid  STRING,
  serviceeventdetails STRING,
  sharedeventid       STRING,
  vpcendpointid       STRING
)
PARTITIONED BY (region string, year string, month string, day string)
ROW FORMAT SERDE 'com.amazon.emr.hive.serde.CloudTrailSerde'
STORED AS INPUTFORMAT 'com.amazon.emr.cloudtrail.CloudTrailInputFormat'
OUTPUTFORMAT 'org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat'
LOCATION 's3://securevoice-dev-cloudtrail-logs-455535733131/AWSLogs/455535733131/CloudTrail/'
TBLPROPERTIES (
  'projection.enabled'        = 'true',
  'projection.region.type'    = 'enum',
  'projection.region.values'  = 'ap-northeast-2,us-east-1',
  'projection.year.type'      = 'integer',
  'projection.year.range'     = '2026,2030',
  'projection.month.type'     = 'integer',
  'projection.month.range'    = '1,12',
  'projection.month.digits'   = '2',
  'projection.day.type'       = 'integer',
  'projection.day.range'      = '1,31',
  'projection.day.digits'     = '2',
  'storage.location.template' = 's3://securevoice-dev-cloudtrail-logs-455535733131/AWSLogs/455535733131/CloudTrail/${region}/${year}/${month}/${day}'
);
```
> 다른 리전 로그도 보려면 `projection.region.values`에 리전을 추가한다(멀티리전 트레일이므로 활동 리전이 폴더로 생성됨).

### 🔍 CloudTrail 보안 쿼리

**Q4. ⭐ 우리 음성 금고(audio 버킷 `uploads/`) 객체 접근 추적 — 작업 B(Data Events)의 결실**
> "누가 어떤 음성 파일을 업로드/다운로드했는가" = 생체정보 접근 감사. 이게 이 프로젝트의 핵심 시연.
```sql
SELECT eventtime,
       useridentity.arn                                   AS who,
       eventname,                                          -- GetObject(다운로드) / PutObject(업로드)
       sourceipaddress                                     AS from_ip,
       json_extract_scalar(requestparameters, '$.key')     AS object_key
FROM securevoice_cloudtrail_logs
WHERE region='ap-northeast-2' AND year='2026' AND month='06'
  AND eventsource='s3.amazonaws.com'
  AND eventname IN ('GetObject','PutObject')
  AND json_extract_scalar(requestparameters, '$.bucketName')
      = 'mzc-securevoiceguard-audio-dev-455535733131-ap-northeast-2-an'
ORDER BY eventtime DESC
LIMIT 100;
```

**Q5. 루트 계정 사용 기록 — 절대 일상 사용하면 안 되는 최고권한 계정 감시**
```sql
SELECT eventtime, eventname, awsregion, sourceipaddress
FROM securevoice_cloudtrail_logs
WHERE year='2026' AND month='06'
  AND useridentity.type = 'Root'
ORDER BY eventtime DESC;
```

**Q6. 보안그룹 변경 이력 — 방화벽 규칙을 누가 건드렸나 (0.0.0.0/0 개방 사고 추적)**
```sql
SELECT eventtime, useridentity.arn AS who, eventname, sourceipaddress,
       requestparameters
FROM securevoice_cloudtrail_logs
WHERE region='ap-northeast-2' AND year='2026' AND month='06'
  AND eventsource='ec2.amazonaws.com'
  AND eventname IN ('AuthorizeSecurityGroupIngress','RevokeSecurityGroupIngress',
                    'AuthorizeSecurityGroupEgress','ModifySecurityGroupRules')
ORDER BY eventtime DESC;
```

**Q7. 콘솔 로그인 + MFA 사용 여부 — 비밀번호만으로 들어온 위험 로그인 색출**
```sql
SELECT eventtime,
       useridentity.username,
       sourceipaddress,
       useridentity.sessioncontext.attributes.mfaauthenticated AS mfa_used,
       errormessage                                            AS login_result
FROM securevoice_cloudtrail_logs
WHERE region='us-east-1' AND year='2026' AND month='06'   -- 콘솔 로그인은 us-east-1에 기록
  AND eventname='ConsoleLogin'
ORDER BY eventtime DESC;
```

**Q8. 특정 IAM 사용자/IP의 모든 행동 추적 — 사고 조사(누가 무엇을 했나) 1줄 변경으로 범용 활용**
```sql
SELECT eventtime, eventsource, eventname, awsregion, sourceipaddress, errorcode
FROM securevoice_cloudtrail_logs
WHERE year='2026' AND month='06'
  AND useridentity.arn LIKE '%user/mzc-pmg%'   -- 조사 대상만 바꿔 재사용
ORDER BY eventtime DESC
LIMIT 200;
```

---

## 3. 발표 시 한 줄 정리

> "로그를 S3+parquet+파티션으로 **싸게 저장**하고, Athena 파티션 프로젝션으로 **수동 관리 없이 즉시 SQL 조사**가 가능합니다.
> 특히 audio `uploads/` Data Events를 Athena로 조회하면 **'누가 어떤 음성에 접근했는가'** 라는 생체정보 감사 질문에
> 바로 답할 수 있습니다 — 이게 탐지에서 조사로 이어지는 마지막 고리입니다."
```
탐지(GuardDuty) ─┐
로깅(CloudTrail) ─┼─→ S3(parquet/파티션) ─→ Athena(이 문서) ─→ 사고 조사 답변
Flow Logs ───────┘                                   ↑ 비용 최적화(스캔 최소화)
```
