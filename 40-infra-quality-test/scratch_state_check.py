import boto3

session = boto3.Session(region_name='ap-northeast-2', profile_name='bya')
ecs = session.client('ecs')
aas = session.client('application-autoscaling')
sqs = session.client('sqs')
cw  = session.client('cloudwatch')

# ECS 서비스 현재 상태
resp = ecs.describe_services(
    cluster='securevoice-dev-cluster',
    services=['securevoice-dev-free-worker-service', 'securevoice-dev-paid-worker-service']
)
for svc in resp['services']:
    name = svc['serviceName']
    print(f"ECS: {name}  running={svc['runningCount']}  desired={svc['desiredCount']}")

# 스케일링 타깃 현재 min/max
targets = [
    ('service/securevoice-dev-cluster/securevoice-dev-free-worker-service', 'free'),
    ('service/securevoice-dev-cluster/securevoice-dev-paid-worker-service', 'paid'),
]
for rid, label in targets:
    r = aas.describe_scalable_targets(
        ServiceNamespace='ecs',
        ResourceIds=[rid],
        ScalableDimension='ecs:service:DesiredCount'
    )
    for t in r['ScalableTargets']:
        print(f"  ScalableTarget [{label}]: min={t['MinCapacity']}, max={t['MaxCapacity']}")

# SQS 큐 상태
queues = [
    ('free-queue', 'https://sqs.ap-northeast-2.amazonaws.com/455535733131/free-queue'),
    ('free-dlq',   'https://sqs.ap-northeast-2.amazonaws.com/455535733131/free-dlq'),
]
for name, url in queues:
    r = sqs.get_queue_attributes(
        QueueUrl=url,
        AttributeNames=['ApproximateNumberOfMessages', 'ApproximateNumberOfMessagesNotVisible']
    )
    a = r['Attributes']
    vis = a['ApproximateNumberOfMessages']
    inv = a['ApproximateNumberOfMessagesNotVisible']
    print(f"SQS {name}: visible={vis}, in-flight={inv}")

# 알람 상태
alarm_names = ['securevoice-free-queue-visible-high', 'securevoice-free-queue-empty']
r = cw.describe_alarms(AlarmNames=alarm_names)
for alarm in r['MetricAlarms']:
    print(f"Alarm: {alarm['AlarmName']}  state={alarm['StateValue']}")
