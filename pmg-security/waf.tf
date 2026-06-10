# =========================================================================
# 0. 글로벌 WAF 생성을 위한 미국 버지니아 북부(us-east-1) 프로바이더 정의
# =========================================================================
provider "aws" {
  alias  = "us_east_1"  # 이 프로바이더 블록을 자원에서 호출할 때 사용할 별명(식별자)입니다.
  region = "us-east-1"  # CloudFront용 글로벌 WAF가 생성되어야 하는 물리적 AWS 리전 위치입니다.
}

# =========================================================================
# 1. 5대 마스터 규칙을 융합한 프리미엄 AWS WAFv2 Web ACL 정의
# =========================================================================
resource "aws_wafv2_web_acl" "main" {
  provider    = aws.us_east_1                           # 위에서 선언한 미국 리전용 프로바이더를 강제 적용합니다.
  name        = "securevoice-dev-waf"                   # AWS 웹 콘솔에 표시될 WAF의 대표 고유 명칭입니다.
  description = "Ultimate WAF combining AWS Defaults and Custom Protections" # 자원의 상세 목적을 명시합니다.
  scope       = "CLOUDFRONT"                            # 최전방 CloudFront 에지 레이어에 장착하기 위한 글로벌 스코프 지정입니다.

  # 5대 규칙에 모두 걸리지 않은 안전한 일반 사용자 트래픽은 기본 통과(Allow)시킵니다.
  default_action {
    allow {}
  }

  # -----------------------------------------------------------------------
  # [규칙 1] AWS Managed IP Reputation List (악성 IP 평판 리스트 - AWS 기본 권장)
  # -----------------------------------------------------------------------
  rule {
    name     = "AWS-AWSManagedRulesAmazonIpReputationList" # AWS가 수집한 전 세계 악성 봇 및 해커 IP 리스트 규칙 이름입니다.
    priority = 1                                        # 악질 해커 IP는 패킷 내부를 볼 필요도 없으므로 1순위로 즉시 필터링합니다.

    override_action {
      count {}                                          # 개발 및 테스트 단계이므로 오탐 방지를 위해 Count(감시)로 작동시킵니다.
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList" # 실제 매핑할 AWS 관리형 규칙 그룹 명칭입니다.
        vendor_name = "AWS"                             # 공급 주체인 AWS를 명시합니다.
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true                 # CloudWatch로 탐지 메트릭 전송을 활성화합니다.
      metric_name                = "AmazonIpReputationMetric" # 지표에 표기될 고유 이름입니다.
      sampled_requests_enabled   = true                 # 탐지된 악성 IP 샘플 수집을 켭니다.
    }
  }

  # -----------------------------------------------------------------------
  # [규칙 2] AWS Managed Core Rule Set (코어 규칙 세트 - 공통 탑재)
  # -----------------------------------------------------------------------
  rule {
    name     = "AWS-AWSManagedRulesCommonRuleSet"       # OWASP Top 10 웹 취약점 패킷 공격을 방어하는 공통 코어 규칙입니다.
    priority = 2                                        # IP 필터링을 통과한 패킷에 대해 2순위로 정밀 해킹 검사를 수행합니다.

    override_action {
      count {}                                          # 정상 오디오 업로드 트래픽 차단 방지를 위해 Count 모드를 유지합니다.
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"    # AWS 매니지드 코어 규칙 그룹 이름입니다.
        vendor_name = "AWS"                             # 공급처를 AWS로 지정합니다.
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true                 # 코어 규칙 탐지 지표 전송을 활성화합니다.
      metric_name                = "CommonRuleSetMetric" # 메트릭 명칭을 매핑합니다.
      sampled_requests_enabled   = true                 # 취약점 공격 패킷의 샘플링 수집을 허용합니다.
    }
  }

  # -----------------------------------------------------------------------
  # [규칙 3] AWS Managed Known Bad Inputs (알려진 악성 입력 세트 - AWS 기본 권장)
  # -----------------------------------------------------------------------
  rule {
    name     = "AWS-AWSManagedRulesKnownBadInputsRuleSet" # Log4j 등 이미 알려진 원격 코드 실행(RCE) 취약점 패킷을 잡아내는 규칙입니다.
    priority = 3                                        # 3순위 단계에서 애플리케이션 치명적 취약점 인풋을 스캔합니다.

    override_action {
      count {}                                          # 안정적인 개발 진행을 위해 초기 Count 모드를 적용합니다.
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet" # AWS 매니지드 악성 인풋 규칙 그룹 명칭입니다.
        vendor_name = "AWS"                             # 공급처를 AWS로 지정합니다.
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true                 # 악성 인풋 탐지 지표 수집을 활성화합니다.
      metric_name                = "KnownBadInputsMetric" # CloudWatch 지표 이름을 매핑합니다.
      sampled_requests_enabled   = true                 # 탐지 패킷 샘플 수집을 허용합니다.
    }
  }

  # -----------------------------------------------------------------------
  # [규칙 4] AWS Managed SQLi Rule Set (SQL 인젝션 방어 세트 - 우리 커스텀 추가)
  # -----------------------------------------------------------------------
  rule {
    name     = "AWS-AWSManagedRulesSQLiRuleSet"         # 데이터베이스 침해 및 백엔드 쿼리 탈취 공격을 방어하는 규칙입니다.
    priority = 4                                        # 데이터 파싱 단계 직전에 4순위로 데이터베이스 전문 방어를 가동합니다.

    override_action {
      count {}                                          # 마찬가지로 오탐 분석을 위해 Count 모드로 설정합니다.
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"      # AWS 매니지드 SQLi 규칙 그룹 명칭입니다.
        vendor_name = "AWS"                             # 공급처를 AWS로 지정합니다.
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true                 # SQLi 메트릭 수집을 활성화합니다.
      metric_name                = "SQLiRuleSetMetric"   # CloudWatch에 표기될 지표 명칭입니다.
      sampled_requests_enabled   = true                 # 공격 패킷 샘플 수집을 켭니다.
    }
  }

  # -----------------------------------------------------------------------
  # [규칙 5] Custom Rate-based Rule (디도스 및 과도한 호출 차단 - 우리 커스텀 추가)
  # -----------------------------------------------------------------------
  rule {
    name     = "DDoS-Rate-Limit-Rule"                   # 특정 IP의 비정상적인 무차별 대량 API 호출을 제한하기 위한 규칙입니다.
    priority = 5                                        # 모든 해킹 패턴 검사가 끝난 정상 패킷에 대해 최종적으로 호출 처리량을 검사합니다.

    # 공격을 목적으로 하는 무차별 매크로/디도스 트래픽이므로 유예 없이 즉각 차단(Block)을 실행합니다.
    action {
      block {} 
    }

    statement {
      rate_based_statement {
        limit              = 2000                       # 연속된 5분(300초) 동안 동일한 IP가 보낼 수 있는 최대 요청 횟수 가드레일입니다.
        aggregate_key_type = "IP"                       # 카운팅 기준을 클라이언트의 '접속 IP 주소'로 지정합니다.
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true                 # 디도스 차단 트래픽 지표 전송을 활성화합니다.
      metric_name                = "DDoSRateLimitMetric" # CloudWatch 메트릭 명칭입니다.
      sampled_requests_enabled   = true                 # 어떤 공격 IP들이 차단 목록에 올라갔는지 샘플을 수집합니다.
    }
  }

  # WAF전체 엔진에 대한 전역 통계 텔레메트리 대시보드 설정입니다.
  visibility_config {
    cloudwatch_metrics_enabled = true                   # Web ACL 전체 트래픽 통계 메트릭 활성화 여부입니다.
    metric_name                = "securevoice-dev-waf-global-metric" # 전역 대시보드 대표 지표 명칭입니다.
    sampled_requests_enabled   = true                   # WAF를 통과/차단한 전체 요청의 샘플링 저장을 허용합니다.
  }

  # 로컬 변수 오류를 제거하고 맵 데이터를 직접 상속 주입합니다.
  tags = {
    Environment = "dev"
    ManagedBy   = "terraform"
  }
}

# =========================================================================
# 2. 수동 관리를 위한 결과값 출력 (Console 연동용)
# =========================================================================
# output "cloudfront_waf_acl_arn" {
#  value       = aws_wafv2_web_acl.main.arn              # 버지니아 리전에 빌드 완료된 완벽한 WAF의 고유 ARN 주소를 터미널에 출력합니다.
#  description = "The ARN of the Global WAF Web ACL. Copy this value for AWS Console binding."
# }