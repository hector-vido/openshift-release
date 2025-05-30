#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"' EXIT TERM

REGION="${LEASED_RESOURCE}"

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
if [[ ${BASE_DOMAIN} == "" ]]; then
  echo "No base_domain provided, exit now."
  exit 1
fi
ROUTE53_HOSTED_ZONE_NAME="${CLUSTER_NAME}.${BASE_DOMAIN}"

VPC_ID=$(cat "${SHARED_DIR}/vpc_id")

# ---------------------------------------------------------------------------
# Create PHZ
# in PHZ account
# ---------------------------------------------------------------------------
echo "AWS Account: using shared account"
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred_shared_account"

cat > /tmp/vpc_phz.yaml << EOF
AWSTemplateFormatVersion: 2010-09-09
Resources:
  VPC:
    Type: "AWS::EC2::VPC"
    Properties:
      CidrBlock: 10.0.0.0/16
      Tags:
      - Key: Name
        Value: !Join [ "-", [ !Ref "AWS::StackName", "cf" ] ]
  PHZ:
    Type: "AWS::Route53::HostedZone"
    DependsOn: VPC
    Properties:
      Name: "${ROUTE53_HOSTED_ZONE_NAME}"
      VPCs:
        -
          VPCId: !Ref VPC
          VPCRegion: !Ref "AWS::Region"
      HostedZoneTags:
        - Key: 'Name'
          Value: !Join [ "-", [ !Ref "AWS::StackName", "phz" ] ]
Outputs:
  PrivateHostedZoneId:
    Value: !Ref PHZ
  VpcId:
    Value: !Ref VPC
EOF
STACK_NAME="${NAMESPACE}-${UNIQUE_HASH}-tmpvpc"
echo ${STACK_NAME} > "${SHARED_DIR}/to_be_removed_cf_stack_list_shared_account"

EXPIRATION_DATE=$(date -d '4 hours' --iso=minutes --utc)
TAGS="Key=expirationDate,Value=${EXPIRATION_DATE}"
aws --region "${REGION}" cloudformation create-stack \
  --stack-name "${STACK_NAME}" \
  --template-body "$(cat /tmp/vpc_phz.yaml)" \
  --tags "${TAGS}" &
wait "$!"
echo "Created stack ${STACK_NAME}"
aws --region "${REGION}" cloudformation wait stack-create-complete --stack-name "${STACK_NAME}" &
wait "$!"
echo "Waited for stack ${STACK_NAME}"

aws --region "${REGION}" cloudformation describe-stacks --stack-name "${STACK_NAME}" > "${SHARED_DIR}/vpc_phz_stack_output"

HOSTED_ZONE_ID=$(jq -r '.Stacks[].Outputs[] | select(.OutputKey=="PrivateHostedZoneId") | .OutputValue' "${SHARED_DIR}/vpc_phz_stack_output")
TEMP_PHZ_VPC_ID=$(jq -r '.Stacks[].Outputs[] | select(.OutputKey=="VpcId") | .OutputValue' "${SHARED_DIR}/vpc_phz_stack_output")
echo "${HOSTED_ZONE_ID}" > "${SHARED_DIR}/hosted_zone_id"
echo "Created Private Hosted Zone ${HOSTED_ZONE_ID} associated ${TEMP_PHZ_VPC_ID}."

echo "Creating VPC association authorization ..."
aws --region ${REGION} route53 create-vpc-association-authorization --hosted-zone-id ${HOSTED_ZONE_ID} --vpc VPCRegion=${REGION},VPCId=${VPC_ID}

# ---------------------------------------------------------------------------
# Associate VPC with hosted zone
# in VPC account 
# ---------------------------------------------------------------------------
echo "AWS Account: using VPC account"
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
echo "Associating PHZ ${HOSTED_ZONE_ID} with VPC ${VPC_ID} ..."
CHANGE_ID=$(aws --region ${REGION} route53 associate-vpc-with-hosted-zone --hosted-zone-id ${HOSTED_ZONE_ID} --vpc VPCRegion=${REGION},VPCId=${VPC_ID} | jq -r '.ChangeInfo.Id' | awk -F / '{printf $3}')
CLUSTER_CREATOR_USER_ARN=$(aws sts get-caller-identity | jq -r '.Arn')


# ---------------------------------------------------------------------------
# in PHZ account
# ---------------------------------------------------------------------------
echo "AWS Account: using shared account"
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred_shared_account"

SHARED_ACCOUNT_NO=$(aws sts get-caller-identity | jq -r '.Arn' | awk -F ":" '{print $5}')

aws --region "${REGION}" route53 wait resource-record-sets-changed --id "${CHANGE_ID}" &
wait "$!"
echo "Associated"



# Create IAM policy
POLICY_NAME="${CLUSTER_NAME}-shared-policy"
POLICY_DOC=$(mktemp)
POLICY_OUT=$(mktemp)

# ec2:DeleteTags is requried, as some tags are added by aws-provision-tags-for-byo-vpc for ingress operator
cat <<EOF> $POLICY_DOC
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": "ec2:DeleteTags",
            "Resource": "arn:aws:ec2:${REGION}:${SHARED_ACCOUNT_NO}:vpc/${VPC_ID}"
        },
        {
            "Effect": "Allow",
            "Action": [
                "route53:ChangeResourceRecordSets",
                "route53:ListHostedZones",
                "route53:ListHostedZonesByName",
                "route53:ListResourceRecordSets",
                "route53:ChangeTagsForResource",
                "route53:GetAccountLimit",
                "route53:GetChange",
                "route53:GetHostedZone",
                "route53:ListTagsForResource",
                "route53:UpdateHostedZoneComment",
                "tag:GetResources",
                "tag:UntagResources"
            ],
            "Resource": "*"
        }
    ]
}
EOF

cmd="aws --region $REGION iam create-policy --policy-name ${POLICY_NAME} --policy-document '$(cat $POLICY_DOC | jq -c)' > ${POLICY_OUT}"
eval "${cmd}"
POLICY_ARN=$(cat ${POLICY_OUT} | jq -r '.Policy.Arn')
echo "Created ${POLICY_ARN}"
echo ${POLICY_ARN} > ${SHARED_DIR}/shared_install_policy_arn

# Create IAM role
ROLE_NAME="${CLUSTER_NAME}-shared-role"
echo ${ROLE_NAME} > ${SHARED_DIR}/shared_install_role_name

ASSUME_ROLE_POLICY_DOC=$(mktemp)
ROLE_OUT=$(mktemp)

PRINCIPAL_LIST=$(mktemp)
echo ${CLUSTER_CREATOR_USER_ARN} > ${PRINCIPAL_LIST}

cat <<EOF> $ASSUME_ROLE_POLICY_DOC
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "AWS": $(cat ${PRINCIPAL_LIST} | jq -Rn '[inputs]')
            },
            "Action": "sts:AssumeRole",
            "Condition": {}
        }
    ]
} 
EOF

aws --region $REGION iam create-role --role-name ${ROLE_NAME} --assume-role-policy-document file://${ASSUME_ROLE_POLICY_DOC} > $ROLE_OUT
ROLE_ARN=$(jq -r '.Role.Arn' ${ROLE_OUT})
echo ${ROLE_ARN} > "${SHARED_DIR}/hosted_zone_role_arn"
echo "Created ${ROLE_ARN} with assume policy:"
cat $ASSUME_ROLE_POLICY_DOC

# Attach policy to role
cmd="aws --region $REGION iam attach-role-policy --role-name ${ROLE_NAME} --policy-arn '${POLICY_ARN}'"
eval "${cmd}"
