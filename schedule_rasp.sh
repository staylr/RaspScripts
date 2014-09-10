# The AWS_CREDENTIAL_FILE and JAVA_HOME environment variables must
# be set before running this command.
# Required software:
#	Amazon CLI (http://aws.amazon.com/cli/)
#	jq
#!/bin/bash
set -x

# "start" or "stop"
env_file=$1
register_mode=$2

if [[ ($register_mode != start
		&& $register_mode != stop
		&& $register_mode != list)
	|| $env_file == "" ]]
then
	echo "Usage: $0 config_file (start|stop)" 2>&1
	exit 1
fi

if [[ ! -f $env_file ]]
then
	echo "Config file $env_file not found" 2>&1
	exit 1
fi

. "$env_file"

# Security group with SSH inbound and unrestricted outbound access.
# Created by this script.
security_group=runrasp-$env
s3access_policy="S3_Access"

# IAM role with write access to $s3bucket. Created by this script.
iam_role=runrasp-$env
iam_instance_profile=${iam_role}-profile

export EC2_URL=https://$region.ec2.amazonaws.com
export AWS_DEFAULT_REGION=$region
export AWS_AUTO_SCALING_URL=https://autoscaling.$region.amazonaws.com

function setup_security()
{
	if [[ "$security_setup" == "true" ]]
	then
		return
	fi

	trust_policy_tmp=/tmp/trust.$$.json
	cat > "$trust_policy_tmp" <<END
{
	"Statement": [{
		"Effect": "Allow",
		"Principal": { "Service": ["ec2.amazonaws.com"] },
		"Action": ["sts:AssumeRole"]
	}]
}
END

	access_policy_tmp=/tmp/access.$$.json
	cat > "$access_policy_tmp" <<END
{
	"Version": "2012-10-17",
	"Statement": [
	{
		"Effect": "Allow",
		"Action": ["s3:ListBucket"],
		"Resource": "arn:aws:s3:::$s3bucket"
	},
        {
                "Effect": "Allow",
                "Action": [
                        "s3:GetObjectAcl",
                        "s3:DeleteObject",
                        "s3:DeleteObjectVersion",
                        "s3:GetObject",
                        "s3:PutObjectAcl",
                        "s3:PutObject"
                ],
                "Resource": "arn:aws:s3:::$s3bucket/*"
        },
        {
                "Effect": "Allow",
                "Action": "s3:ListBucket",
                "Resource": "arn:aws:s3:::$config_s3bucket"
        },
        {
                "Effect": "Allow",
                "Action": "s3:GetObject",
                "Resource": "arn:aws:s3:::$config_s3bucket/*"
        }]
}
END

	aws iam create-role --role-name "${iam_role}" \
			--assume-role-policy-document "file://$trust_policy_tmp"

	aws iam put-role-policy --role-name "${iam_role}" \
			--policy-name "$s3access_policy" \
			--policy-document "file://$access_policy_tmp"

	aws iam create-instance-profile \
			--instance-profile-name "$iam_instance_profile"

	aws iam add-role-to-instance-profile \
			--instance-profile-name "$iam_instance_profile" \
			--role-name "$iam_role"

	aws ec2 create-security-group \
			--group-name "$security_group" \
			--description "RASP env $env"

	# Open SSH access.
	aws ec2 authorize-security-group-ingress \
			--group-name "$security_group" \
			--protocol tcp --port 22 --cidr '0.0.0.0/0'

	# Later operations may fail on missing instance profiles
	# without this.
	sleep 10

	aws iam list-instance-profiles | jq -c .

	rm "$trust_policy_tmp"
	rm "$access_policy_tmp"
}

function delete_security()
{
	aws iam remove-role-from-instance-profile \
			--instance-profile-name "$iam_instance_profile" \
			--role-name "$iam_role"
	aws iam delete-instance-profile \
			--instance-profile-name "$iam_instance_profile"
	aws iam delete-role-policy \
			--role-name "$iam_role" \
			--policy-name "$s3access_policy"
	aws iam delete-role --role-name "$iam_role"
	aws ec2 delete-security-group --group-name "$security_group"
	sleep 10
}

function register_auto_scale()
{
	regions=$1
	run_time=$2
	stop_time=$3
	auto_scale_group=$4
	user_data_tmp_file="/tmp/aws_user_data.$$"
	
	if [[ "$register_mode" == "start" ]]
	then
		# Create script to run RASP on specified regions.
		cat > "$user_data_tmp_file" <<END
#!/bin/bash

export BASEDIR=/home/admin/DRJACK

/usr/local/bin/disable.hyperthreading

s3cmd -c /home/ubuntu/.s3cfg sync "s3://$config_s3bucket/scripts/rasp_forecast.sh" "/home/admin/rasp_forecast.sh"
s3cmd  -c /home/ubuntu/.s3cfg sync "s3://$config_s3bucket/config/rasp.run.parameters.*" "\$BASEDIR/RASP/RUN/"
s3cmd  -c /home/ubuntu/.s3cfg sync "s3://$config_s3bucket/config/rasp.ncl.region.data" "\$BASEDIR/WRF/NCL/rasp.ncl.region.data"
s3cmd  -c /home/ubuntu/.s3cfg sync "s3://$config_s3bucket/config/rasp.ncl" "\$BASEDIR/WRF/NCL/rasp.ncl"
chown admin /home/admin/rasp_forecast.sh
chmod +x /home/admin/rasp_forecast.sh

cd /home/admin
nohup sudo -n -i -u admin ./rasp_forecast.sh --s3bucket "s3://$s3bucket" --archive --shutdown $regions >& /var/log/rasp.log &
END

		# Create auto-scale group, one per schedule.
		aws autoscaling create-launch-configuration \
			--instance-type "$instance_type" \
			--image-id $ami_id \
			--key-name "$aws_key" \
			--launch-configuration-name \
					"${auto_scale_group}-config" \
			--spot-price "$spot_price" \
			--iam-instance-profile "${iam_instance_profile}" \
			--security-groups "$security_group" \
			--user-data "file://$user_data_tmp_file"

		aws autoscaling create-auto-scaling-group \
			--auto-scaling-group-name "$auto_scale_group" \
			--launch-configuration-name \
					"${auto_scale_group}-config" \
			--availability-zones ${launch_region[@]} \
			--min-size 0 --max-size 0

		aws autoscaling suspend-processes \
			--auto-scaling-group-name "$auto_scale_group" \
			--scaling-processes ReplaceUnhealthy

		rm "$user_data_tmp_file"
		
		# Create start and stop actions.
		aws autoscaling put-scheduled-update-group-action \
			--scheduled-action-name \
				"${auto_scale_group}-schedule-start" \
			--auto-scaling-group-name "$auto_scale_group" \
			--min-size 1 \
			--max-size 1 \
			--recurrence "$run_time * * *"

		aws autoscaling put-scheduled-update-group-action \
			--scheduled-action-name \
				"${auto_scale_group}-schedule-stop" \
			--auto-scaling-group-name "$auto_scale_group" \
			--min-size 0 \
			--max-size 0 \
		 	--recurrence "$stop_time * * *"

		aws autoscaling put-notification-configuration \
			--auto-scaling-group-name "$auto_scale_group" \
			--topic-arn "$sns_topic" --notification-type \
			autoscaling:EC2_INSTANCE_LAUNCH_ERROR \
			autoscaling:EC2_INSTANCE_TERMINATE

	elif [[ "$register_mode" == "stop" ]]
	then
		aws autoscaling delete-scheduled-action \
			--scheduled-action-name \
				"${auto_scale_group}-schedule-start" \
			--auto-scaling-group-name "$auto_scale_group"

		aws autoscaling delete-scheduled-action \
			--scheduled-action-name \
				"${auto_scale_group}-schedule-stop" \
			--auto-scaling-group-name "$auto_scale_group"

		aws autoscaling update-auto-scaling-group \
			--auto-scaling-group-name "$auto_scale_group" \
			--min-size 0 \
			--max-size 0

		aws autoscaling delete-auto-scaling-group \
			--force-delete \
			--auto-scaling-group-name "$auto_scale_group"

		aws autoscaling delete-launch-configuration \
			--launch-configuration-name "${auto_scale_group}-config"
	fi
}

if [[ $register_mode == start ]]
then
	setup_security
fi

if [[ $register_mode == start || $register_mode == stop ]]
then
	register_zones
	sleep 10
fi

if [[ $register_mode == stop ]]
then
	delete_security
fi


aws autoscaling describe-launch-configurations | jq -c '.LaunchConfigurations[] | {LaunchConfigurationName:.LaunchConfigurationName,SpotPrice:.SpotPrice,SecurityGroups:.SecurityGroups,KeyName:.KeyName,InstanceType:.InstanceType,IamInstanceProfile:.IamInstanceProfile}'

aws autoscaling describe-auto-scaling-groups | jq -c '.AutoScalingGroups[] | {AutoScalingGroupName:.AutoScalingGroupName,MaxSize:.MaxSize,LaunchConfigurationName:.LaunchConfigurationName}'

aws autoscaling describe-scheduled-actions | jq -c '.ScheduledUpdateGroupActions[] | {ScheduledActionName:.ScheduledActionName,AutoScalingGroupName:.AutoScalingGroupName,Recurrence:.Recurrence,MaxSize:.MaxSize}'

aws autoscaling describe-auto-scaling-instances | jq -c '.AutoScalingInstances[]'

