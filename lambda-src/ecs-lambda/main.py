import json
import boto3

ecs_client = boto3.client('ecs')
elbv2_client = boto3.client('elbv2')

def prewarmHtmlString(service):
    return """ \
        <html>
        <head>
        <title>Preview Environment Spinning up</title>
        <meta http-equiv="refresh" content="10" >
        </head>
        <body>
        <h1> ECS Task Turnip - We'll get you spinning in no time!</h1>
        <h2>Your preview environment <code>{service}</code> is spinning up. This page will refresh automatically every 10 seconds to check.
        <br /></br >Once your task is ready, you will be automatically redirected to your preview environment</h1>
        </body>
        </html>
        """.format(service=service)

def getECSServiceObjectAtr(cluster, service, attribute):
    try:
        return ecs_client.describe_services(
            cluster=cluster,
            services=[
                service,
            ]
        )['services'][0][attribute]
    except KeyError:
        return json.dumps({"error": "invalid_key_returned_from_ecs_service_info"})

def updateECSServiceTaskCount(cluster, service, desiredTaskCount):
    try:
        ecs_start_response = ecs_client.update_service(
            cluster=cluster,
            service=service,
            desiredCount=desiredTaskCount,
        )
        return prewarmHtmlString(service)
    except:
        return json.dumps({"error": "issue_starting_ecs_task"})

def getELBV2ObjectAtr(lb_arn, attribute):
    try:
        return elbv2_client.describe_load_balancers(LoadBalancerArns=[ lb_arn ])["LoadBalancers"][0][attribute]
    except KeyError:
        return json.dumps({"error": "invalid_key_returned_from_elbv2_describe_info"})

def findListenerPortFromTGARN(lb_arn, tg_arn):
    try:
        lb_listeners = elbv2_client.describe_listeners(LoadBalancerArn=lb_arn)['Listeners']

        for listener in lb_listeners:
            for tg in listener["DefaultActions"]:
                for fwd_cfg in tg["ForwardConfig"]:
                    if tg["ForwardConfig"][fwd_cfg][0]['TargetGroupArn'] == tg_arn:
                        return {"port": listener["Port"], "protocol": listener["Protocol"]}
    except Exception as e:
        print(e)
        return json.dumps({"error": "invalid_response_returned_from_elbv2_describe_listeners"})

def lambda_handler(event, context):
    try:
        service = event['queryStringParameters']['service']
    except:
        return json.dumps({"error": "invalid_or_null_service"})
        
    try:
        cluster = event['queryStringParameters']['cluster']
    except:
        return json.dumps({"error": "invalid_or_null_cluster"})

    # BEGIN MAIN LOGIC
    try:
        desired_count = getECSServiceObjectAtr(cluster, service, "desiredCount")
        running_count = getECSServiceObjectAtr(cluster, service, "runningCount")
        
        if desired_count == 0:
            return updateECSServiceTaskCount(cluster, service, 1)
        elif (desired_count > 0 and running_count < 1):
            return prewarmHtmlString(service)
        else:
            tg_details = getECSServiceObjectAtr(cluster, service, "loadBalancers")
            tg_arn = tg_details[0]["targetGroupArn"]

            lb_arn = elbv2_client.describe_target_groups(TargetGroupArns=[tg_arn])['TargetGroups'][0]['LoadBalancerArns'][0]

            targetgroup_health = elbv2_client.describe_target_health(TargetGroupArn=tg_arn)['TargetHealthDescriptions']

            lb_dns_name = getELBV2ObjectAtr(lb_arn, "DNSName")
            lb_name = getELBV2ObjectAtr(lb_arn, "LoadBalancerName")

            isHealthy = 0
            for tg in targetgroup_health:
                if tg['TargetHealth']['State'] == "healthy":
                    isHealthy = 1
            if isHealthy == 1:
                print("in isHealthy 1 now")
                redirect_data = findListenerPortFromTGARN(lb_arn, tg_arn)
                print(redirect_data)
                response = {}
                response["statusCode"]=302
                response["headers"]={'Location': '{protocol}://{lb_dns_name}:{lb_port}'.format(protocol=redirect_data.get('protocol').lower(), lb_dns_name=lb_dns_name, lb_port=redirect_data.get('port'))}
                data = {}
                response["body"]=json.dumps(data)
                return response
            else:
                return prewarmHtmlString(service)
    except Exception as e:
        print(e)
        return json.dumps({"error": "issue_in_processing_ecs_spinup"})
        
