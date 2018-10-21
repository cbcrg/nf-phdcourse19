#!/bin/bash
# MIT License
# 
# Copyright (c) 2018, Centre for Genomic Regulation (CRG).
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
# 
set -e 
set -u 

X_TYPE=${1:-t2.xlarge}
X_DISK=${2:-50}
X_AMI=${3:-$(curl -fsSL http://169.254.169.254/latest/meta-data/ami-id)}
X_SUBNET=${4:-subnet-05222a43} 
X_RND=$(dd bs=12 count=1 if=/dev/urandom 2>/dev/null | base64 | tr +/ 0A)
X_MARKER=.launcher-$X_RND
X_ZONE=`curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone`

export AWS_DEFAULT_REGION="`echo \"$X_ZONE\" | sed 's/[a-z]$//'`"

function getRootDevice() {
  local ami=$1
  local size=$2

  local str="$(aws ec2 describe-images --image-ids $ami --query 'Images[*].{ID:BlockDeviceMappings}' --output text)"
  local device=$(echo "$str" | grep ID | cut -f 2)
  local delete=$(echo "$str" | grep EBS | cut -f 2 | tr '[:upper:]' '[:lower:]')
  local snapsh=$(echo "$str" | grep EBS | cut -f 4)
  local type=$(echo "$str" | grep EBS | cut -f 6)

cat << EndOfString
{
    "DeviceName": "$device",
    "Ebs": {
        "DeleteOnTermination": $delete,
        "SnapshotId": "$snapsh",
        "VolumeSize": $size,
        "VolumeType": "$type"
    }
}
EndOfString

}

function spinner() {
    local pid=$1
    local delay=0.75
    local spinstr='|/-\'
    while [ -e $X_MARKER ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    #printf "    \b\b\b\b"
}

touch $X_MARKER
echo "~~ N E X T F L O W  -  C O U R S E ~~" 
echo "" 
echo "Launching EC2 virtual machine" 
echo "- type  : $X_TYPE" 
echo "- ami   : $X_AMI" 
echo "- disk  : $X_DISK GB"
echo "- subnet: $X_SUBNET"
echo ""

# Ask for confirmation 
read -u 1 -p "* Please confirm you want to launch an VM with these settings [y/n] " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then echo ABORTED; exit 1; fi

# Launch a Ec2 instance  
OUT=$(aws ec2 run-instances --image-id $X_AMI --instance-type $X_TYPE --subnet-id $X_SUBNET --block-device-mappings "[$(getRootDevice $X_AMI $X_DISK)]" --output text)

X_ID=$(echo "$OUT" | grep INSTANCES | cut -f 8)
X_STATE=$(echo "$OUT" | grep STATE | head -n 1 | cut -f 3) 
echo  ""
echo "* Instance launched >> $X_ID <<"  
echo -n "* Waiting for ready status .. "
spinner $$ &
spinner_pid=$!

# tag the instance 
aws ec2 create-tags --resources $X_ID --tags Key=Name,Value="User: $(hostname)"

# Wait for instance in `running` status
while [ $X_STATE = pending ]; do 
    sleep 5
    OUT=$(aws ec2 describe-instances --instance-ids $X_ID --output text)
    X_STATE=$(echo "$OUT" | grep STATE | cut -f 3)   
done

if [ $X_STATE != running ]; then
  echo "* Oops .. something went wrong :("
  echo ""
  echo "$OUT"
  exit 1
fi 
  
# Fetch the publish host name   
X_IP=$(echo "$OUT" | grep ASSOCIATION | head -n 1 | cut -f 3)

# Probe SSH connection until it's avalable 
X_READY=''
while [ ! $X_READY ]; do
    sleep 10
    set +e
    OUT=$(ssh -o ConnectTimeout=1 -o StrictHostKeyChecking=no -o BatchMode=yes ec2-user@$X_IP 2>&1 | grep 'Permission denied' )
    [[ $? = 0 ]] && X_READY='ready'
    set -e
done 

rm $X_MARKER
wait $spinner_pid 2>/dev/null

# Done
echo "  ssh me@$X_IP" > $HOME/launch-ec2.log
echo ""
echo ""
echo "* The instance is ready!"
echo "* Open a new shell terminal and login with the following command:" 
echo "" 
echo "  ssh me@$X_IP"
echo ""
