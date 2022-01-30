var AWS = require('aws-sdk');
AWS.config.update({region: 'us-east-1'});
var ecs = new AWS.ECS({apiVersion: '2014-11-13'});
var elbv2 = new AWS.ELBv2({apiVersion: '2015-12-01'});

async function returnPrewarmHTML(previewName) {
    return `
        <html>
        <head>
        <title>Preview Environment Spinning up</title>
        <meta http-equiv="refresh" content="10" >
        </head>
        <body>
        <h1> ECS Task Turnip - We'll get you spinning in no time!</h1>
        <h2>Your preview environment <code>${previewName}</code> is spinning up. This page will refresh automatically every 10 seconds to check.
        <br /></br >Once your task is ready, you will be automatically redirected to your preview environment</h1>
        </body>
        </html>`
}

async function getECSServiceObjectAtrs(cluster, service) {
   let ecsReturn = await ecs.describeServices({cluster: cluster, services: [service]}).promise();
   return {
        'desiredCount': ecsReturn['services'][0]['desiredCount'],
        'runningCount': ecsReturn['services'][0]['runningCount'],
        'loadBalancer': ecsReturn['services'][0]['loadBalancers'][0],
    }
}

async function updateECSServiceTaskCount(cluster, service, desiredTaskCount) {
    let ecsStart = await ecs.updateService({cluster: cluster, service: service, desiredCount: desiredTaskCount}).promise();
    let response = {
        statusCode: 200,
        body: await returnPrewarmHTML(service),
        headers: {"Content-Type": "text/html; charset=UTF-8"}
    };
    console.log("response: " + JSON.stringify(response))
    return response;
}

async function getELBV2ObjectAtr(lbArn) {
    let elbReturn = await elbv2.describeLoadBalancers({LoadBalancerArns: [lbArn]}).promise();

    return {
        "DNSName": elbReturn['LoadBalancers'][0]['DNSName'],
        "LoadBalancerName": elbReturn['LoadBalancers'][0]['LoadBalancerName']
    };
}

async function findListenerPortFromTGARN(lbArn, tgArn) {
    const lbListenersObj = await elbv2.describeListeners({LoadBalancerArn: lbArn}).promise();
    const lbListeners = lbListenersObj['Listeners'];

    for (const listener of lbListeners) {
        for (const tg of listener['DefaultActions']) {
            for (const fwd_cfg in tg['ForwardConfig']) {
                if (tg['ForwardConfig'][fwd_cfg][0]['TargetGroupArn'] == tgArn) {
                    return {
                        "port": listener['Port'], 
                        "protocol": listener['Protocol']
                    };
                }
            }
        }
    }
}

// exports.handler = (event, context, callback) => {
exports.handler = async (event) => {
    console.log('EVENT: ' + JSON.stringify(event, null, 2));
    let service = event.queryStringParameters.service;
    let cluster = event.queryStringParameters.cluster;

    console.log(`servicename: ${service} | clustername: ${cluster}`);

    const ecsSvcAtr = await getECSServiceObjectAtrs(cluster, service);
    const [desiredCount, runningCount, tgArn] = [ecsSvcAtr['desiredCount'], ecsSvcAtr['runningCount'], ecsSvcAtr['loadBalancer']['targetGroupArn']];
    
    console.log(`desiredCount: ${desiredCount} | runningCount: ${runningCount} | tgArn: ${tgArn}`);

    if (desiredCount == 0) {
        return await updateECSServiceTaskCount(cluster, service, 1);
    }
    else if (desiredCount > 0 && runningCount < 1){
        let response = {
            statusCode: 200,
            body: await returnPrewarmHTML(service),
            headers: {"Content-Type": "text/html; charset=UTF-8"}
        };
        console.log("response: " + JSON.stringify(response))
        return response;
    }
    else {
        const tgAtrs = await elbv2.describeTargetGroups({TargetGroupArns: [tgArn]}).promise();
        const lbArn = tgAtrs['TargetGroups'][0]['LoadBalancerArns'][0]

        let tgHealthObj = await elbv2.describeTargetHealth({TargetGroupArn: tgArn}).promise();
        const tgHealth = tgHealthObj['TargetHealthDescriptions'];
        let lbObj = await getELBV2ObjectAtr(lbArn);
        let lbDNSName = lbObj['DNSName'];

        let isHealthy = 0;

        for (const tg of tgHealth) {
            if (tg['TargetHealth']['State'] == "healthy"){
                isHealthy = 1;
            }
        }

        if (isHealthy == 1) {
            console.log('isHealthy 1 now');
            let redirectData = await findListenerPortFromTGARN(lbArn, tgArn);

            let response = {
                statusCode: 302,
                headers: {
                    "Location" : `${redirectData['protocol'].toLowerCase()}://${lbDNSName}:${redirectData['port']}`
                },
                body: JSON.stringify('')
            };
            console.log("response: " + JSON.stringify(response))
            return response;
        }
        else {
            let response = {
                statusCode: 200,
                body: await returnPrewarmHTML(service),
                headers: {"Content-Type": "text/html; charset=UTF-8"}
            };
            console.log("response: " + JSON.stringify(response))
            return response;
        }
    }
};
