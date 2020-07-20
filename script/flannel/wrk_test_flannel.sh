#!/bin/bash
set -x

HOST_TYPE="thunderx2"
TEST_TIME=10

#MTU_SIZES=(1480,5480,8980)
MTU_SIZES=(1480 2000 3000 4000 5000 6000 7000 8000 8980)
MTU_WITHOUT_IPIP=(5000 6000 7000 8000 9000)
#MTU_WITHOUT_IPIP=(3000 4000)


HOST_USER="jingzhao"
HOST_USER_PWD="arm"

# For master and slave host, the eth interface is used for data transmission.
# In this script, it will be configured with different MTU size. Please modify it based on your configurations
LOCAL_ETH_DEV="ens3f0"
REMOTE_ETH_DEV="ens3f0"

#sudo ip link set dev enp12s0f1 up

function wait_for {
  # Execute in a subshell to prevent local variable override during recursion
  (
    local total_attempts=$1; shift
    local cmdstr=$*
    local sleep_time=2
    echo -e "\n[wait_for] Waiting for cmd to return success: ${cmdstr}"
    # shellcheck disable=SC2034
    for attempt in $(seq "${total_attempts}"); do
      echo "[wait_for] Attempt ${attempt}/${total_attempts%.*} for: ${cmdstr}"
      # shellcheck disable=SC2015
      eval "${cmdstr}" && echo "[wait_for] OK: ${cmdstr}" && return 0 || true
      sleep "${sleep_time}"
    done
    echo "[wait_for] ERROR: Failed after max attempts: ${cmdstr}"
    return 1
  )
}

# Checking the interface mtu size. If the size is not correct, return error
#Input: $1 interface name
#       $2 mtu size
check_mtu(){
  ETH=$1
  SET_SIZE=$2

  eth_size=$(ip link show $ETH |grep mtu |awk '{print $5}')

  if [ ${eth_size} -ne ${SET_SIZE} ]; then
    echo "$ETH size is not correct, real: ${eth_size}, setting ${SET_SIZE}"
    exit 1
  fi
}

check_remote_mtu(){

  ETH=$1
  SET_SIZE=$2
  HOST=$3

  USER=$HOST_USER
  PWD=$HOST_USER_PWD

  COMMAND="ip link show $ETH |grep mtu |awk '{print \$5}'"
  eth_size=$(sshpass -p $PWD ssh -o StrictHostKeyChecking=no $USER@$HOST ${COMMAND})

  if [ ${eth_size} -ne ${SET_SIZE} ]; then
    echo "$ETH of $3 size is not correct, real: ${eth_size}, setting ${SET_SIZE}"
    exit 1
  fi
}

config_eth_mtu(){
  ETH=$1
  MTU=$2
  MODE=$3

  sudo ip link delete cni0

  if [ $MODE == "ipip" ]; then
    sudo ip link delete flannel.ipip | true
  elif [ $MODE == "vxlan" ]; then
    sudo ip link delete flannel.1 | true
  fi

  sudo ifconfig $1 mtu $2
}

config_remote_eth_mtu(){
  ETH=$1
  MTU=$2
  MODE=$3
  HOST=$4

  USER=$HOST_USER
  PWD=$HOST_USER_PWD

  sshpass -p $PWD ssh -o StrictHostKeyChecking=no $USER@$HOST "sudo ip link delete cni0"

  if [ $MODE == "ipip" ]; then
    sshpass -p $PWD ssh -o StrictHostKeyChecking=no $USER@$HOST "sudo ip link delete flannel.ipip"
  elif [ $MODE == "vxlan" ]; then
    sshpass -p $PWD ssh -o StrictHostKeyChecking=no $USER@$HOST "sudo ip link delete flannel.1"
  fi

  sshpass -p $PWD ssh -o StrictHostKeyChecking=no $USER@$HOST "sudo ifconfig $1 mtu $2"
}

check_configurations(){
  MTU=$1
  type=$2
  remote=$3

  if [ $type == "ipip" ]; then
    OVER_HEADER=20
    FLANNEL_BRI="flannel.ipip"
  elif [ $type == "vxlan" ]; then
    OVER_HEADER=50
    FLANNEL_BRI="flannel.1"
  fi

  let "bri_mtu=$MTU-$OVER_HEADER"

  USER=$HOST_USER
  PWD=$HOST_USER_PWD


  If_perf=$(brctl show cni0| grep cni0 | awk '{print $4}')

  COMMAND="brctl show cni0| grep cni0 | awk '{print \$4}'"
  If_perf_remote=$(sshpass -p $PWD ssh -o StrictHostKeyChecking=no $USER@$remote ${COMMAND})

  # Local host
  check_mtu cni0 $bri_mtu
  check_mtu ${FLANNEL_BRI} $bri_mtu
  check_mtu ${If_perf} $bri_mtu
  check_mtu $LOCAL_ETH_DEV $MTU


  # remote
  check_remote_mtu cni0 $bri_mtu $remote
  check_remote_mtu ${FLANNEL_BRI} $bri_mtu $remote
  check_remote_mtu ${If_perf_remote} $bri_mtu $remote
  check_remote_mtu $REMOTE_ETH_DEV $MTU $remote

}

restart_flannel(){
  # $1 -> flannel mtu(with/without ip-ip)
  mtu_flannel=$1

  # Stop flannel in K8s
  kubectl delete -f ./files/kube-flannel.yml || true
  wait_for 30 'test $(kubectl get pods -n kube-system | grep flannel -c ) -lt 1'

  # Replace mtu & Start flannel
  kubectl apply -f ./files/kube-flannel.yml

  wait_for 50 'test $(kubectl get pods -n kube-system | grep flannel |grep Running -c ) -eq 2'

}

restart_flannelipip(){
  # $1 -> flannel mtu(with/without ip-ip)
  mtu_flannel=$1

  # Stop flannel in K8s
  kubectl delete -f ./files/kube-flannelIPIP.yml || true
  wait_for 30 'test $(kubectl get pods -n kube-system | grep flannel -c ) -lt 1'

  # Replace mtu & Start flannel
  kubectl apply -f ./files/kube-flannelIPIP.yml

  wait_for 50 'test $(kubectl get pods -n kube-system | grep flannel |grep Running -c ) -eq 2'
}

wrk_test_prepare(){
	Client=$1
	#Delete nginx server
	kubectl delete -f files/nginx-app-files.yaml
	#Delete wrk client
	kubectl delete -f files/wrk-app.yaml

	wait_for 30 'test $(kubectl get pods | grep wrk -c ) -lt 1'

	# Replace the wrk host name
	sed -i "/^      kubernetes.io\/hostname/c\ \ \ \ \ \ \ \ kubernetes.io\/hostname: ${Client}" ./files/wrk-app.yaml

	kubectl apply -f files/nginx-app-files.yaml
	wait_for 30 'test $(kubectl get pods | grep nginx |grep Running -c ) -eq 2'

	kubectl apply -f files/wrk-app.yaml
	wait_for 30 'test $(kubectl get pods | grep wrk |grep Running -c ) -eq 1'
}

wrk_test_start(){

	MTU_SIZE=$1
	MODE=$2 # "ipip" or "vxlan"
	SERVER=$3

	#WRK_FILES=(10K.file 100K.file 1M.file 10M.file 100M.file)
	WRK_FILES=(10K.file 100K.file 1M.file 10M.file)

	#POD_IP=$(kubectl get pods -o wide| grep nginx | grep ${SERVER} |cut -f45 -d' ')
	POD_IP=$(kubectl get pods -o wide| grep nginx | grep ${SERVER} |cut -f25 -d' ')

	WRK_TEST_CMD="/usr/bin/wrk -t12 -c1000 -d30s http://${POD_IP}/files/${file}"

	# Local host <-> pod test
	echo "Wrk http test from local host----> nginx Pod IP: ${POD_IP}"
	TEST_TYPE="host2pod"
	for file in "${WRK_FILES[@]}"
	do
		echo "FILE: ${file}"
		wrk -t12 -c1000 -d30s http://${POD_IP}/files/${file} >> ./test_results/wrk_${TEST_TYPE}_${MODE}_${MTU_SIZE}_${file}.txt
		sleep 2
	done

	# pod < - > pod test
	echo "Wrk http test from local pod <----> nginx Pod IP: ${POD_IP}"
	TEST_TYPE="pod2pod"
	for file in "${WRK_FILES[@]}"
	do
		echo "FILE: ${file}"
		kubectl exec -it wrk-app -- ${WRK_TEST_CMD} >> ./test_results/wrk_${TEST_TYPE}_${MODE}_${MTU_SIZE}_${file}.txt
		sleep 3
	done
}

config_mtu(){
  MTU=$1
  MODE=$2
  REMOTE=$3

  # local host
  config_eth_mtu $LOCAL_ETH_DEV $MTU $MODE

  # remote host
  config_remote_eth_mtu $REMOTE_ETH_DEV $MTU $MODE $REMOTE
}

# Mtu size: 
#          IPIP enable  1480 <--> 8980
#          IPIP disable 1500 <--> 9000

# vxlan mtu size: 1500 <--> 9000
# Test wrk
for MTU in "${MTU_WITHOUT_IPIP[@]}"
do
  use_ipip="vxlan"

  config_mtu $MTU $use_ipip "net-x86-supermicro-03"

  # Configure Flannel
  restart_flannel ${MTU}

  #test_wrk
  wrk_test_prepare "net-x86-dell-01"

  check_configurations ${MTU} $use_ipip "net-x86-supermicro-03"

  wrk_test_start $MTU $use_ipip "net-x86-supermicro-03"

  #echo "${HOST_TYPE} node2pod Mtu: ${MTU} vxlan testing"
  #test_node2pod "node2pod" ${TEST_TIME} ${MTU} "vxlan"
done

for MTU in "${MTU_WITHOUT_IPIP[@]}"
do
  use_ipip="ipip"

  config_mtu $MTU $use_ipip "net-x86-supermicro-03"

  # Configure Flannel
  restart_flannelipip ${MTU}

  #test_wrk
  wrk_test_prepare "net-x86-dell-01"

  check_configurations ${MTU} $use_ipip "net-x86-supermicro-03"

  wrk_test_start $MTU $use_ipip "net-x86-supermicro-03"

  #echo "${HOST_TYPE} node2pod Mtu: ${MTU} vxlan testing"
  #test_node2pod "node2pod" ${TEST_TIME} ${MTU} "vxlan"
done
