#!/bin/bash


#Variable Declaration
JQ="jq --raw-output --exit-status"
DEPLOYMENT_TYPE=""
ENV=""
BUILD_VARIABLE_FILE_NAME="./buildvar.conf"
SECRET_FILE_NAME="./buildsecvar.conf"
SHARED_PROPERTY_FILENAME=""

#Common Varibles
AWS_ACCESS_KEY_ID=""
AWS_SECRET_ACCESS_KEY=""
AWS_ACCOUNT_ID=""
AWS_REGION=""
TAG=""
SEC_LIST=""
COUNTER_LIMIT=12

#Varibles specific to ECS
AWS_REPOSITORY=""
AWS_ECS_CLUSTER=""
AWS_ECS_SERVICE=""
AWS_ECS_TASK_FAMILY=""
AWS_ECS_CONTAINER_NAME=""
ECS_TAG=""
REVISION=""
ECS_TEMPLATE_TYPE="EC2"
task_def=""
CONTAINER_LOG_DRIVER="awslogs"
portcount=0
envcount=0
volcount=0
template=""
TEMPLATE_SKELETON_FILE="base_template_v2.json"

#variable specific to EBS
EBS_APPLICATION_NAME=""
EBS_APPVER=""
EBS_TAG=""
IMAGE=""
AWS_EBS_APPVER=""
AWS_S3_BUCKET=""
AWS_S3_KEY=""
AWS_EB_ENV=""
EBS_TEMPLATE_FILE_NAME=""
AWS_EBS_EB_DOCKERRUN_TEMPLATE_LOCATION=$(eval "echo \$${ENV}_AWS_EBS_EB_DOCKERRUN_TEMPLATE_LOCATION")
AWS_EBS_DOCKERRUN_TEMPLATE=$(eval "echo \$${ENV}_AWS_EBS_DOCKERRUN_TEMPLATE")
AWS_S3_KEY_LOCATION=""

#variable for cloud front
AWS_S3_BUCKET=""
AWS_S3_SOURCE_SYNC_PATH=""
CFCACHE="true"

#FUNCTIONS
#usage Function - provides information like how to execute the script
usage()
{
cat << EOF
usage: $0 options

This script need to be executed with below option.

OPTIONS:
 -h      Show this message
 -d      Deployment Type [ECS|EBS|CFRONT]
 -e      Environment [DEV|QA|PROD]
 -t      ECS Tag Name [mandatatory if ECS ]
 -v      EBS version   [mandatatory if  EBS deployment]
 -c		 cache option true [optional : value = true| false]i
 -s      Security file location GIT|AWS
 -p      ECS template type
 -g      Enter common property file which has uploaded in shared-properties folder
EOF
}
#log Function - Used to provide information of execution information with date and time
log()
{
   echo "`date +'%D %T'` : $1"
}
#track_error function validates whether the application execute without any error

track_error()
{
   if [ $1 != "0" ]; then
        log "$2 exited with error code $1"
        log "completed execution IN ERROR at `date`"
        exit $1
   fi

}


#Function for aws login

configure_aws_cli() {
	aws --version
	aws configure set aws_access_key_id $AWS_ACCESS_KEY_ID
	aws configure set aws_secret_access_key $AWS_SECRET_ACCESS_KEY
	aws configure set default.region $AWS_REGION
	aws configure set default.output json
	log "Configured AWS CLI."
}
#Function for private dcoker login
configure_docker_private_login() {
	aws s3 cp "s3://appirio-platform-$ENV_CONFIG/services/common/dockercfg" ~/.dockercfg
}

#ECS Deployment Functions

ECS_push_ecr_image() {
	log "Pushing Docker Image..."
	eval $(aws ecr get-login --region $AWS_REGION --no-include-email)
	docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$AWS_REPOSITORY:$ECS_TAG
	track_error $? "ECS ECR image push"
	log "Docker Image published."
}

#================
portmapping() {
hostport=$1
containerport=$2
containerprotocol=$3

template=$(echo $template | jq --argjson hostPort $hostport --argjson containerPort $containerport --arg protocol $containerprotocol  --arg portcount $portcount '.containerDefinitions[0].portMappings[$portcount |tonumber] |= .+ { hostPort: $hostPort, containerPort: $containerPort, protocol: $protocol  }')
let portcount=portcount+1

}
#=============================


envaddition() {
    #echo "envcount before " $envcount
    
envname=$1
envvalue=$2
#echo "env value before" $envvalue
template=$(echo $template | jq --arg name "$envname" --arg value "$envvalue" --arg envcount $envcount '.containerDefinitions[0].environment[$envcount |tonumber] |= .+ { name: $name, value: $value  }')

let envcount=envcount+1
#echo "envcount after ---------" $envcount
#echo "envvalue after ---------" $envvalue
}
#=========================
logconfiguration() {
template=$(echo $template | jq --arg logDriver $CONTAINER_LOG_DRIVER '.containerDefinitions[0].logConfiguration.logDriver=$logDriver')
template=$(echo $template | jq --arg awslogsgroup "/aws/ecs/$AWS_ECS_CLUSTER" '.containerDefinitions[0].logConfiguration.options."awslogs-group"=$awslogsgroup')
template=$(echo $template | jq --arg awslogsregion $AWS_REGION '.containerDefinitions[0].logConfiguration.options."awslogs-region"=$awslogsregion')
template=$(echo $template | jq --arg awslogsstreamprefix $ENV '.containerDefinitions[0].logConfiguration.options."awslogs-stream-prefix"=$awslogsstreamprefix')
template=$(echo $template | jq  'del(.containerDefinitions[0].logConfiguration.options.KeyName)')
}
#=============================================
volumeupdate() {
  volname=$1
  sourcepath=$2
  mountpath=$3
  #mntpermission=$4
  #echo $volname $sourcepath $mountpath $mntpermission
  #volumes update
  template=$(echo $template | jq --arg volname $volname --arg sourcepath $sourcepath --arg volcount $volcount '.volumes[$volcount |tonumber] |= .+ { name: $volname, host: { sourcePath: $sourcepath } }')
  #mount point update
  template=$(echo $template | jq --arg volname $volname --arg mountpath $mountpath --arg volcount $volcount '.containerDefinitions[0].mountPoints[$volcount |tonumber] |= .+ { sourceVolume: $volname, containerPath: $mountpath }')

  let volcount=volcount+1
}
#============================================


ECS_template_create_register() {

#Getting Template skeleton
#template=`aws ecs register-task-definition --generate-cli-skeleton`
template=$(cat $TEMPLATE_SKELETON_FILE)

#Updating ECS task def file
template=$(echo $template | jq --arg family $AWS_ECS_TASK_FAMILY '.family=$family')
log "Family updated"

#taskrole and excution role has updated 
template=$(echo $template | jq --arg taskRoleArn arn:aws:iam::$AWS_ACCOUNT_ID:role/ecsTaskExecutionRole '.taskRoleArn=$taskRoleArn')
template=$(echo $template | jq --arg executionRoleArn arn:aws:iam::$AWS_ACCOUNT_ID:role/ecsTaskExecutionRole '.executionRoleArn=$executionRoleArn')

#Container Name update
template=$(echo $template | jq --arg name $AWS_ECS_CONTAINER_NAME '.containerDefinitions[0].name=$name')
log "Container Name updated"

#Container Image Name update
template=$(echo $template | jq --arg image $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$AWS_REPOSITORY:$ECS_TAG '.containerDefinitions[0].image=$image')
log "Image name updated"

#Container Memory reservation
if [ -z $AWS_ECS_CONTAINER_MEMORY_RESERVATION ];
then
  log "No reseveed memory defined . Going with default value 500 MB"
  AWS_ECS_CONTAINER_MEMORY_RESERVATION="1000"
  template=$(echo $template | jq --argjson memoryReservation $AWS_ECS_CONTAINER_MEMORY_RESERVATION '.containerDefinitions[0].memoryReservation=$memoryReservation')
else 
  template=$(echo $template | jq --argjson memoryReservation $AWS_ECS_CONTAINER_MEMORY_RESERVATION '.containerDefinitions[0].memoryReservation=$memoryReservation')
fi
log "Memory reservation updated"

#Port Mapping
Buffer_portmap=$(echo $AWS_ECS_PORTS | sed 's/,/ /g')
for b1 in $Buffer_portmap;
do
  hostport=$( echo $b1 | cut -d ':' -f 1 ) 
  containerport=$( echo $b1 | cut -d ':' -f 2 ) 
  protocolmapped=$( echo $b1 | cut -d ':' -f 3 ) 
  portmapping $hostport $containerport $protocolmapped
done
log "port mapping updated"
# Environment addition
Buffer_seclist=$(echo $SEC_LIST | sed 's/,/ /g')
for listname in $Buffer_seclist;
do
    local o=$IFS
    IFS=$(echo -en "\n\b")
    envvars=$( cat $listname.json | jq  -r ' . ' | jq ' . | to_entries[] | { "name": .key , "value": .value } ' | jq '  select(.name | test("AWS.") | not ) ' | jq -s . )
    log "vars are fetched"
    for s in $(echo $envvars | jq -c ".[]" ); do
     #echo $envvars
        varname=$(echo $s| jq -r ".name")
        varvalue=$(echo $s| jq -r ".value")
        envaddition "$varname" "$varvalue"
    done
    IFS=$o  
done

log "environment has updated"
# Log Configuration
logconfiguration
log "log configuration has updated"

#volume update
if [ -z $AWS_ECS_VOLUMES ];
then
    echo "No volume mapping defined"
else
    Buffer_volumes=$(echo $AWS_ECS_VOLUMES | sed 's/,/ /g')
    for v1 in $Buffer_volumes;
    do
        volname=$( echo $v1 | cut -d ':' -f 1 ) 
        sourcepath=$( echo $v1 | cut -d ':' -f 2 ) 
        mountpath=$( echo $v1 | cut -d ':' -f 3 ) 
        #mntpermission=$( echo $v1 | cut -d ':' -f 4 ) 
        #volumeupdate $volname $sourcepath $mountpath $mntpermission
        volumeupdate $volname $sourcepath $mountpath
    done
    log "volumes are mapped"
fi 

#updating data based on ECS deploy type
if [ "$ECS_TEMPLATE_TYPE" == "FARGATE" ]
then
    #updating Network
    ECS_NETWORKTYPE="awsvpc"
    template=$(echo $template | jq --arg networkMode $ECS_NETWORKTYPE '.networkMode=$networkMode')
    # Updating the compatibiltiy
    template=$(echo $template | jq --arg requiresCompatibilities EC2 '.requiresCompatibilities[0] |= .+ $requiresCompatibilities')
    template=$(echo $template | jq --arg requiresCompatibilities FARGATE '.requiresCompatibilities[.requiresCompatibilities| length] |= .+ $requiresCompatibilities')
    # Updating Fargate CPU
    if [ -z $AWS_ECS_FARGATE_CPU ];
    then
      echo "No  FARGATE cpu defined . Going with default value 1024"   
      AWS_ECS_FARGATE_CPU="1024"   
      template=$(echo $template | jq --argjson cpu $AWS_ECS_FARGATE_CPU '.cpu=$cpu')
    else
      template=$(echo $template | jq --argjson cpu $AWS_ECS_FARGATE_CPU '.cpu=$cpu')    
    fi
    # Updating Fargate Memory
    if [ -z $AWS_ECS_FARGATE_MEMORY ];
    then
      echo "No  FARGATE memory defined . Going with default value 2048"  
      AWS_ECS_FARGATE_MEMORY="2048"
      template=$(echo $template | jq --argjson memory $FARGATE_MEMORY '.memory=$memory')
    else
      template=$(echo $template | jq --argjson memory $FARGATE_MEMORY '.memory=$memory')
    fi
else
    #CONTAINER_CPU
    ECS_NETWORKTYPE="bridge"
    template=$(echo $template | jq --arg networkMode $ECS_NETWORKTYPE '.networkMode=$networkMode')
    #Container Memory reservation
    if [ -z $AWS_ECS_CONTAINER_CPU ];
    then
      echo "No  cpu defined . Going with default value 100"
      AWS_ECS_CONTAINER_CPU=100
      template=$(echo $template | jq --argjson cpu $AWS_ECS_CONTAINER_CPU '.containerDefinitions[0].cpu=$cpu')
    else 
      template=$(echo $template | jq --argjson cpu $AWS_ECS_CONTAINER_CPU '.containerDefinitions[0].cpu=$cpu')
    fi
    
    # Updating the compatibiltiy
    template=$(echo $template | jq --arg requiresCompatibilities EC2 '.requiresCompatibilities[0] =  $requiresCompatibilities')
fi
if [ -z "$template" ]; 
      then 
         track_error 1 "Task Def has not set by template variable"
      else
      echo "template values ------:" $template
        if REVISION=$(aws ecs register-task-definition --cli-input-json "$template" | $JQ '.taskDefinition.taskDefinitionArn'); then
          log "Revision: $REVISION"
        else
          track_error 1 "Task Def registration"
          log "Failed to register task definition"
          return 1
        fi
fi
}

ECS_deploy_cluster() {

    AWS_ECS_SERVICE=$1
    update_result=$(aws ecs update-service --cluster $AWS_ECS_CLUSTER --service $AWS_ECS_SERVICE --task-definition $REVISION )
    result=$(echo $update_result | $JQ '.service.taskDefinition' )
    log $result
    if [[ $result != $REVISION ]]; then
        #echo "Error updating service."
		track_error 1 "ECS updating service."	
        return 1
    fi

    echo "Update service intialised successfully for deployment"
    return 0
}

check_service_status() {
        AWS_ECS_SERVICE=$1
        counter=0
		sleep 60
        servicestatus=`aws ecs describe-services --service $AWS_ECS_SERVICE --cluster $AWS_ECS_CLUSTER | $JQ '.services[].events[0].message'`
        while [[ $servicestatus != *"steady state"* ]]
        do
           echo "Current event message : $servicestatus"
           echo "Waiting for 15 sec to check the service status...."
           sleep 15
           servicestatus=`aws ecs describe-services --service $AWS_ECS_SERVICE --cluster $AWS_ECS_CLUSTER | $JQ '.services[].events[0].message'`
           counter=`expr $counter + 1`
           if [[ $counter -gt $COUNTER_LIMIT ]] ; then
                echo "Service does not reach steady state with in 180 seconds. Please check"
                exit 1
           fi
        done
        echo "$servicestatus"
}

# EBS integration


EBS_push_docker_image() {

echo "pushing docker image: ${IMAGE}"
docker push $IMAGE
track_error $? "docker push failed."

}

creating_updating_ebs_docker_json() {
cd $AWS_EBS_EB_DOCKERRUN_TEMPLATE_LOCATION
cat $AWS_EBS_DOCKERRUN_TEMPLATE | sed -e "s/@IMAGE@/${EBS_TAG}/g" > $DOCKERRUN
jar cMf ${EBS_TAG}.zip $DOCKERRUN .ebextensions
echo "pushing ${EBS_TAG}.zip to S3: ${AWS_S3_BUCKET}/${AWS_S3_KEY}"
aws s3api put-object --bucket "${AWS_S3_BUCKET}" --key "${AWS_S3_KEY}" --body ${EBS_TAG}.zip
track_error $? "aws s3api put-object failed."
}

creating_updating_EBS_appversion() {

echo "creating new application version $AWS_EBS_APPVER in ${EBS_APPLICATION_NAME} from s3:${AWS_S3_BUCKET}/${AWS_S3_KEY}"
aws elasticbeanstalk create-application-version --application-name $EBS_APPLICATION_NAME --version-label $AWS_EBS_APPVER --source-bundle S3Bucket="$AWS_S3_BUCKET",S3Key="$AWS_S3_KEY"
track_error $? "aws elasticbeanstalk create-application-version failed."

echo "updating elastic beanstalk environment ${AWS_EB_ENV} with the version ${AWS_EBS_APPVER}."
# assumes beanstalk app for this service has already been created and configured
aws elasticbeanstalk update-environment --environment-name $AWS_EBS_ENV_NAME --version-label $AWS_EBS_APPVER
track_error $? "aws elasticbeanstalk update-environment failed."

}

#Cloud Front DEPLOYMENT

deploy_s3bucket() {
	echo -e "application/font-woff\t\t\t\twoff2" >> /etc/mime.types
	echo -e "application/font-sfnt\t\t\t\tttf" >> /etc/mime.types
	echo -e "application/json\t\t\t\tmap" >> /etc/mime.types

	cat /etc/mime.types  | grep -i woff
	cat /etc/mime.types  | grep -i ico
	cat /etc/mime.types  | grep -i map
	cat /etc/mime.types  | grep -i ttf
	if [ "$CFCACHE" = "true" ]; then
        S3_CACHE_OPTIONS="--cache-control max-age=0,s-maxage=86400"
	else
		S3_CACHE_OPTIONS="--cache-control private,no-store,no-cache,must-revalidate,max-age=0"
		echo "*** Deploying with Cloudfront Cache disabled ***"
	fi

	S3_OPTIONS="--exclude '*.txt' --exclude '*.js' --exclude '*.css'"
	echo aws s3 sync $AWS_S3_SOURCE_SYNC_PATH s3://${AWS_S3_BUCKET} ${S3_CACHE_OPTIONS} ${S3_OPTIONS}
	eval "aws s3 sync --dryrun $AWS_S3_SOURCE_SYNC_PATH s3://${AWS_S3_BUCKET} ${S3_CACHE_OPTIONS} ${S3_OPTIONS}"
	result=`eval "aws s3 sync $AWS_S3_SOURCE_SYNC_PATH s3://${AWS_S3_BUCKET} ${S3_CACHE_OPTIONS} ${S3_OPTIONS}"`
	if [ $? -eq 0 ]; then
		echo "All html, font, image, map and media files are Deployed without gzip encoding!"
	else
		echo "Deployment Failed  - $result"
		exit 1
	fi

	S3_OPTIONS="--exclude '*' --include '*.txt' --include '*.js' --include '*.css' --content-encoding gzip"
	echo aws s3 sync --dryrun $AWS_S3_SOURCE_SYNC_PATH s3://${AWS_S3_BUCKET} ${S3_CACHE_OPTIONS} ${S3_OPTIONS}
	eval "aws s3 sync --dryrun $AWS_S3_SOURCE_SYNC_PATH s3://${AWS_S3_BUCKET} ${S3_CACHE_OPTIONS} ${S3_OPTIONS}"
	result=`eval "aws s3 sync $AWS_S3_SOURCE_SYNC_PATH s3://${AWS_S3_BUCKET} ${S3_CACHE_OPTIONS} ${S3_OPTIONS}"`
	if [ $? -eq 0 ]; then
		echo "All txt, css, and js files are Deployed! with gzip"
	else
		echo "Deployment Failed  - $result"
		exit 1
	fi
}

decrypt_fileenc()
{
    Buffer_seclist=$(echo $SEC_LIST | sed 's/,/ /g' )
    for listname in $Buffer_seclist;
    do
        cp $HOME/buildscript/securitymanager/$listname.json.enc .
        SECPASSWD=$(eval "echo \$${listname}")
        openssl enc -aes-256-cbc -d -md MD5 -in $listname.json.enc -out $listname.json -k $SECPASSWD
    done
}

# decrypt_aws_sys_parameter()
# {

#    for future implmentation.
# }

# Input Collection and validation
input_parsing_validation()
{
while getopts .d:h:e:t:v:s:p:g:c:. OPTION
do
     case $OPTION in
         d)
             DEPLOYMENT_TYPE=$OPTARG
             ;;
         h)
             usage
             exit 1
             ;;
         e)
             ENV=$OPTARG
             ;;
         t)
             TAG=$OPTARG
             ;;
         c)
             CFCACHE=$OPTARG
             ;;			 
         v)
             EBS_APPVER=$OPTARG
             ;;
         s)
             SEC_LIST=$OPTARG
             ;;
         p)
             ECS_TEMPLATE_TYPE=$OPTARG
             ;;
         g)
             SHARED_PROPERTY_FILENAME=$OPTARG
             ;;

         ?)
             log "additional param required"
             usage
             exit
             ;;
     esac
done

if [ -z $DEPLOYMENT_TYPE ] || [ -z $ENV ] ;
then
     log "Param validation error"
     usage
     exit 1
fi

log "ENV        :       $ENV"
log "DEPLOYMENT_TYPE    :       $DEPLOYMENT_TYPE"
ENV_CONFIG=`echo "$ENV" | tr '[:upper:]' '[:lower:]'`

#Validating AWS configuration

AWS_ACCESS_KEY_ID=$(eval "echo \$${ENV}_AWS_ACCESS_KEY_ID")
AWS_SECRET_ACCESS_KEY=$(eval "echo \$${ENV}_AWS_SECRET_ACCESS_KEY")
AWS_ACCOUNT_ID=$(eval "echo \$${ENV}_AWS_ACCOUNT_ID")
AWS_REGION=$(eval "echo \$${ENV}_AWS_REGION")
if [ -z $AWS_ACCESS_KEY_ID ] || [ -z $AWS_SECRET_ACCESS_KEY ] || [ -z $AWS_ACCOUNT_ID ] || [ -z $AWS_REGION ];
then
     log "AWS Secret Parameters are not configured in circleci/environment"
     usage
     exit 1
else
     configure_aws_cli
     #aws configure list
fi

#Getting Deployment varaible only


decrypt_fileenc


Buffer_seclist=$(echo $SEC_LIST | sed 's/,/ /g')
for listname in $Buffer_seclist;
do
  for envappvar in $( cat $listname.json | jq  -r ' . ' | jq ' . | to_entries | map(select(.key | test("AWS.") ) ) | from_entries'  | jq -r "to_entries|map(\"\(.key)=\(.value|tostring)\")|.[]" ); do
      export $envappvar
  done
done

#Validating parameter based on Deployment type
#ECS parameter validation
if [ "$DEPLOYMENT_TYPE" == "ECS" ]
then
  ECS_TAG=$TAG
  cp $HOME/buildscript/$TEMPLATE_SKELETON_FILE .

  if [ -z $AWS_REPOSITORY ] || [ -z $AWS_ECS_CLUSTER ] || [ -z $AWS_ECS_SERVICE ] || [ -z $AWS_ECS_TASK_FAMILY ] || [ -z $AWS_ECS_CONTAINER_NAME ] || [ -z $AWS_ECS_PORTS ] || [ -z $ECS_TAG ];
  then
     log "Deployment varibale are not updated. Please check tag option has provided. also ensure AWS_REPOSITORY, AWS_ECS_TASK_FAMILY,AWS_ECS_CONTAINER_NAME,AWS_ECS_PORTS,AWS_ECS_CLUSTER and AWS_ECS_SERVICE ariables are configured on secret manager"
     usage
     exit 1
  fi
  log "AWS_REPOSITORY           :       $AWS_REPOSITORY"
  log "AWS_ECS_CLUSTER    :       $AWS_ECS_CLUSTER"
  log "AWS_ECS_SERVICE_NAMES  :       $AWS_ECS_SERVICE"
  log "AWS_ECS_TASK_FAMILY    : $AWS_ECS_TASK_FAMILY"
  log "AWS_ECS_CONTAINER_NAME   :       $AWS_ECS_CONTAINER_NAME"
  log "AWS_ECS_PORTS  :       $AWS_ECS_PORTS"
  log "ECS_TAG  :       $ECS_TAG"
fi
#EBS parameter validation
if [ "$DEPLOYMENT_TYPE" == "EBS" ]
then
  EBS_APPLICATION_NAME=$(eval "echo \$${ENV}_EBS_APPLICATION_NAME")
  AWS_EBS_ENV_NAME=$(eval "echo \$${ENV}_AWS_EBS_ENV_NAME")
  AWS_EBS_APPVER="${AWS_EBS_ENV_NAME}-${EBS_APPVER}"
  EBS_TAG="${IMAGE_NAME}:${ENV_CONFIG}.${EBS_APPVER}"
  IMAGE="${DOCKER_REGISTRY_NAME}/${EBS_TAG}"
  AWS_S3_BUCKET=$(eval "echo \$${ENV}_AWS_S3_BUCKET")
  AWS_S3_KEY_LOCATION=$(eval "echo \$${ENV}_AWS_S3_KEY_LOCATION")
  if [ "$AWS_S3_KEY_LOCATION" = "" ] ;
  then
    AWS_S3_KEY="${EBS_TAG}"
  else
    AWS_S3_KEY="$AWS_S3_KEY_LOCATION/${EBS_TAG}"
  fi
  AWS_EBS_EB_DOCKERRUN_TEMPLATE_LOCATION=$(eval "echo \$${ENV}_AWS_EBS_EB_DOCKERRUN_TEMPLATE_LOCATION")
  AWS_EBS_DOCKERRUN_TEMPLATE=$(eval "echo \$${ENV}_AWS_EBS_DOCKERRUN_TEMPLATE")
  if [ -z $EBS_APPLICATION_NAME ] || [ -z $AWS_EBS_ENV_NAME ] || [ -z $EBS_APPVER ] || [ -z $AWS_EBS_APPVER ]  || [ -z $EBS_TAG ] || [ -z $IMAGE ] || [ -z $AWS_S3_BUCKET ] || [ -z $AWS_EBS_EB_DOCKERRUN_TEMPLATE_LOCATION ] || [ -z $AWS_EBS_DOCKERRUN_TEMPLATE ];
  then
     log "Build varibale are not updated. Please update the Build variable file"
     usage
     exit 1
  fi
  log "EBS_APPLICATION_NAME           :       $EBS_APPLICATION_NAME"
  log "EBS_APPVER    :       $EBS_APPVER"
  log "AWS_EBS_APPVER	: 	$AWS_EBS_APPVER"
  log "EBS_TAG  :       $EBS_TAG"
  log "IMAGE    : $IMAGE"
  log "AWS_S3_BUCKET   :       $AWS_S3_BUCKET"
  log "AWS_S3_KEY :       $AWS_S3_KEY"
  log "AWS_EB_ENV  :       $AWS_EBS_ENV_NAME"
fi
#CFRONT parameter validation
if [ "$DEPLOYMENT_TYPE" == "CFRONT" ]
then

 if [ -z $AWS_S3_BUCKET ] || [ -z $AWS_S3_SOURCE_SYNC_PATH ];
  then
     log "Build varibale are not updated. Please update the Build variable file"
     usage
     exit 1
  fi
  log "AWS_S3_BUCKET   :       $AWS_S3_BUCKET"
  log "AWS_S3_SOURCE_SYNC_PATH  :       $AWS_S3_SOURCE_SYNC_PATH"
fi
}

# Main

main()
{

input_parsing_validation $@

if [ "$DEPLOYMENT_TYPE" == "ECS" ]
then
	#ECS_push_ecr_image
	ECS_template_create_register
    echo "value of AWS_ECS_SERVICE " $AWS_ECS_SERVICE
	AWS_ECS_SERVICE_NAMES=$(echo ${AWS_ECS_SERVICE} | sed 's/,/ /g')
    #AWS_ECS_SERVICE_NAMES=$(echo ${AWS_ECS_SERVICE} | sed 's/,/ /g' | sed 'N;s/\n//')
    echo "value of AWS_ECS_SERVICE_NAMES " $AWS_ECS_SERVICE_NAMES
	IFS=' ' read -a AWS_ECS_SERVICES <<< $AWS_ECS_SERVICE_NAMES
	if [ ${#AWS_ECS_SERVICES[@]} -gt 0 ]; then
		 echo "${#AWS_ECS_SERVICES[@]} service are going to be updated"
		 for AWS_ECS_SERVICE_NAME in "${AWS_ECS_SERVICES[@]}"
		 do
		   echo "updating ECS Cluster Service - $AWS_ECS_SERVICE_NAME"
		   ECS_deploy_cluster "$AWS_ECS_SERVICE_NAME"
		   check_service_status "$AWS_ECS_SERVICE_NAME"
		   #echo $REVISION
		 done
	else
		 echo "Kindly check the service name in Parameter"
		 usage
		 exit 1
	fi
	
fi


if [ "$DEPLOYMENT_TYPE" == "EBS" ]
then
	configure_aws_cli
	configure_docker_private_login
	EBS_push_docker_image
	creating_updating_ebs_docker_json
	creating_updating_EBS_appversion
fi

if [ "$DEPLOYMENT_TYPE" == "CFRONT" ]
then
	deploy_s3bucket
fi
}
main $@
