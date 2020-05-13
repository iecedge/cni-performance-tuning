#!/bin/bash
#set -x

HOST_TYPE="thunderx2"
TEST_TIME=10

#MTU_SIZES=(1480,5480,8980)
MTU_SIZES=(1480 2000 3000 4000 5000 6000 7000 8000 8980)
MTU_WITHOUT_IPIP=(1500 2000 3000 4000 5000 6000 7000 8000 9000)

HTTP_SERVER_HOSTNAME="net-arm-thunderx2-04"
HTTP_SERVER_ACCESSIP=192.168.2.1
HTTP_SERVER2_ACCESSIP=192.168.2.2

HTTP_SERVER_HOSTNAME2="net-arm-thunderx2-02"
HTTP_SERVER_HOSTNAME_FQDN="net-arm-thunderx2-04.shanghai.arm.com"
HTTP_SERVER_HOSTNAME2_FQDN="net-arm-thunderx2-02.shanghai.arm.com"
HTTP_SERVER_HOSTNAME2="net-arm-thunderx2-02"
HTTP_CLIENT_HOSTNAME="net-arm-thunderx2-02.shanghai.arm.com"
HTTP_CLIENT_MGMTIP="10.169.41.165"
HOST_USER="trevor"
HOST_USER_PWD="arm"

nic_mtu_size=$(ip link |grep enp12s0f1 | cut -f 5 -d' ')


sudo ip link set dev enp12s0f1 up

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


restart_calico()
{
  # $1 -> Calico mtu(with/without ip-ip)
  mtu_calico=$1

  # Stop calico in K8s
  kubectl delete -f ./files/calico.yaml || true
  wait_for 30 'test $(kubectl get pods -n kube-system | grep calico -c ) -lt 1'

  # Replace mtu & Start calico
  sed -i "/^  veth_mtu:/c\ \ veth_mtu: \"${mtu_calico}\"" calico.yaml
  kubectl apply -f calico.yaml

  wait_for 50 'test $(kubectl get pods -n kube-system | grep calico |grep Running -c ) -eq 3'
}

restart_perf()
{
  #Server="net-arm-thunderx2-04"
  #Client="net-arm-thunderx2-02"
  Server=$1
  Client=$2
  # Delete perf server & client
  kubectl delete -f iperf-client.yaml
  kubectl delete -f iperf-server.yaml
  wait_for 30 'test $(kubectl get pods | grep perf -c ) -lt 1'

  # Start perf server & client
  sed -i "/^        kubernetes.io\/hostname/c\ \ \ \ \ \ \ \ kubernetes.io\/hostname: ${Client}" iperf-client.yaml
  sed -i "/^        kubernetes.io\/hostname/c\ \ \ \ \ \ \ \ kubernetes.io\/hostname: ${Server}" iperf-server.yaml
  kubectl apply -f iperf-server.yaml
  kubectl apply -f iperf-client.yaml
  
  wait_for 50 'test $(kubectl get pods | grep iperf |grep Running -c ) -eq 2'
}

config_IPIP(){
  IPIP=$1
  sed -i "s/Always/$1/g" calico.yaml
  sed -i "s/CrossSubnet/$1/g" calico.yaml
}

test_perf(){
  type=$1
  time=$2
  mtu=$3
  ipip_mode=$4

  sleep 10
  SERVER_IP=$(kubectl get pods -o wide| grep iperf-server |cut -f25 -d' ')
  CLIENT_POD=$(kubectl get pods | grep iperf-client |cut -f1 -d' ')

  # iperf -c ${SERVER_IP} -t ${time} -i 1 -w 100K -P 4
  # -l packet length: default is 8k
  PERF_CMD="iperf -c ${SERVER_IP} -t ${time} -i 1 -w 100K -P 4"
  kubectl exec -it ${CLIENT_POD} -- ${PERF_CMD} >> ./test_results/${HOST_TYPE}_${type}_${ipip_mode}_${mtu}.txt

}

test_node2pod(){
  type=$1
  time=$2
  mtu=$3
  ipip_mode=$4

  sleep 10
  SERVER_IP=$(kubectl get pods -o wide| grep iperf-server |cut -f25 -d' ')

  iperf -c ${SERVER_IP} -t ${time} -i 1 -w 100K -P 4 >> ./test_results/${HOST_TYPE}_${type}_${ipip_mode}_${mtu}.txt
  # -l packet length: default is 8k

}

get_items(){

  string=$1
  OLD_IFS="$IFS"
  IFS=" "
  array=($string)
  IFS="$OLD_IFS"

  for var in ${array[@]}
  do
     echo $var
  done

  echo "Get the item"
  echo ${array[eval($2)]}

}


wrk_filenames=(600bytes.txt 10K.file 100K.file 1M.file 10M.file 100M.file 500M.file)

test_wrk(){

  echo "MTU: "${MTU}
  Server=$1
  Client=$2
  #Delete nginx server
  kubectl delete -f nginx-app-files.yaml
  #Delete wrk client
  kubectl delete -f wrk-tx2-02.yaml
  
  wait_for 30 'test $(kubectl get pods | grep wrk -c ) -lt 1'

  #Start Nginx server and svc
  kubectl apply -f nginx-app-files.yaml
  #Start wrk client on thunderx2-02
  kubectl apply -f wrk-tx2-02.yaml
  wait_for 50 'test $(kubectl get pods | grep nginx |grep Running -c ) -eq 2'
  wait_for 50 'test $(kubectl get pods | grep wrk |grep Running -c ) -eq 1'

  svcIP=$(kubectl get services nginx  -o json | grep clusterIP | cut -f4 -d'"')
  svcNodePort=$(kubectl get services nginx  -o json | grep nodePort | cut -f2 -d':' | cut -f1 -d',' | cut -f2 -d' ')

  nginx_pod_string=$(kubectl get pods -o wide| grep nginx |grep ${HTTP_SERVER_HOSTNAME})
  OLD_IFS="$IFS"
  IFS=" "
  array=($nginx_pod_string)
  IFS="$OLD_IFS"
  NGINX_POD_IP1=${array[5]}


  nginx_pod_string=$(kubectl get pods -o wide| grep nginx |grep ${HTTP_SERVER_HOSTNAME2})
  OLD_IFS="$IFS"
  IFS=" "
  array=($nginx_pod_string)
  IFS="$OLD_IFS"
  NGINX_POD_IP2=${array[5]}

  WRK_POD=$(kubectl get pods | grep -i "wrk-tx2" |cut -f1 -d' ')

  echo "ServiceIP:"$svcIP
  echo "ServiceNodePort:"$svcNodePort
  echo "Nginx Pod IP on "${HTTP_SERVER_HOSTNAME}": "$NGINx_POD_IP1
  echo "Nginx Pod IP on "${HTTP_SERVER_HOSTNAME2}": "$NGINx_POD_IP2
  echo "WRK_POD is:"$WRK_POD

for file in "${wrk_filenames[@]}"
do
  echo "Wrk http test from tx2-02 host----> nginx Pod IP:"
  WRK_TEST_CMD="/usr/bin/wrk -t12 -c1000 -d30s http://${NGINX_POD_IP1}/files/${file}"
  echo $WRK_TEST_CMD
  TEST_TYPE="host2pod"
  file="./test_results/wrk_${TEST_TYPE}_${use_ipip}_${MTU}.txt"
  echo "Write to file:"$file
  echo $WRK_TEST_CMD >> ./test_results/wrk_${TEST_TYPE}_${use_ipip}_${MTU}.txt
  sshpass -p ${HOST_USER_PWD} ssh -o StrictHostKeyChecking=no ${HOST_USER}@${HTTP_CLIENT_HOSTNAME} ${WRK_TEST_CMD} >> ./test_results/wrk_${TEST_TYPE}_${use_ipip}_${MTU}.txt
  sleep 3
done


for file in "${wrk_filenames[@]}"
do
  echo "Wrk http test from tx2-02 wrk Pod ----> nginx Pod :"
  WRK_TEST_CMD="wrk -t12 -c1000 -d30s http://${NGINX_POD_IP1}/files/${file}"
  echo $WRK_TEST_CMD
  TEST_TYPE="pod2pod"
  file="./test_results/wrk_${TEST_TYPE}_${use_ipip}_${MTU}.txt"
  echo $WRK_TEST_CMD >> $file
  kubectl exec -it ${WRK_POD} -- ${WRK_TEST_CMD} >> ./test_results/wrk_${TEST_TYPE}_${use_ipip}_${MTU}.txt
  sleep 3
done


for file in "${wrk_filenames[@]}"
do
  echo "Wrk http test from tx2-02 wrk Pod ----> k8s service by nodeIP:nodePort"
  #WRK_TEST_CMD="wrk -t12 -c1000 -d30s http://${HTTP_SERVER_HOSTNAME_FQDN}:${svcNodePort}/files/${file}"
  WRK_TEST_CMD="wrk -t12 -c1000 -d30s http://${HTTP_SERVER_ACCESSIP}:${svcNodePort}/files/${file}"
  echo $WRK_TEST_CMD
  TEST_TYPE="pod2nodeIPnodePort"
  echo $WRK_TEST_CMD >> ./test_results/wrk_${TEST_TYPE}_${use_ipip}_${MTU}.txt
  kubectl exec -it ${WRK_POD} -- ${WRK_TEST_CMD} >> ./test_results/wrk_${TEST_TYPE}_${use_ipip}_${MTU}.txt
  sleep 3
done

for file in "${wrk_filenames[@]}"
do
  echo "Wrk http test from tx2-02 host ----> k8s service by nodeIP:nodePort"
  WRK_TEST_CMD="wrk -t12 -c1000 -d30s http://${HTTP_SERVER_ACCESSIP}:${svcNodePort}/files/${file}"
  echo $WRK_TEST_CMD
  TEST_TYPE="host2nodeIPnodePort"
  echo $WRK_TEST_CMD >> ./test_results/wrk_${TEST_TYPE}_${use_ipip}_${MTU}.txt
  sshpass -p ${HOST_USER_PWD} ssh -o StrictHostKeyChecking=no ${HOST_USER}@${HTTP_CLIENT_HOSTNAME} ${WRK_TEST_CMD} >> ./test_results/wrk_${TEST_TYPE}_${use_ipip}_${MTU}.txt
  sleep 3
done


for file in "${wrk_filenames[@]}"
do
  echo "Wrk http test from tx2-02 host ----> k8s service by svcIP"
  WRK_TEST_CMD="wrk -t12 -c1000 -d30s http://${svcIP}/files/${file}"
  echo $WRK_TEST_CMD
  TEST_TYPE="host2svc"
  echo $WRK_TEST_CMD >> ./test_results/wrk_${TEST_TYPE}_${use_ipip}_${MTU}.txt
  sshpass -p ${HOST_USER_PWD} ssh -o StrictHostKeyChecking=no ${HOST_USER}@${HTTP_CLIENT_HOSTNAME} ${WRK_TEST_CMD} >> ./test_results/wrk_${TEST_TYPE}_${use_ipip}_${MTU}.txt
  sleep 3
done

}

#Test http performance from tx2-02 to tx2-04 of baremetal

test_http_baremetal(){

for file in "${wrk_filenames[@]}"
do
  echo "Wrk http test from tx2-02 node ----> tx2-04 node"
  #WRK_TEST_CMD="wrk -t12 -c1000 -d30s http://${HTTP_SERVER_HOSTNAME}/files/${file}"
  WRK_TEST_CMD="wrk -t12 -c1000 -d30s http://${HTTP_SERVER_ACCESSIP}/files/${file}"
  echo $WRK_TEST_CMD
  TEST_TYPE="node2node"
  echo ${WRK_TEST_CMD} >> ./test_results/wrk_${TEST_TYPE}_baremetal_nicmtu${nic_mtu_size}.txt
  echo ""
  sshpass -p ${HOST_USER_PWD} ssh -o StrictHostKeyChecking=no ${HOST_USER}@${HTTP_CLIENT_HOSTNAME} ${WRK_TEST_CMD} >> ./test_results/wrk_${TEST_TYPE}_baremetal_nicmtu${nic_mtu_size}.txt
  sleep 3
done
}


#test_http_baremetal


# Mtu size: 
#          IPIP enable  1480 <--> 8980
#          IPIP disable 1500 <--> 9000

# IPIP mtu size: 1480 <--> 8980
for MTU in "${MTU_SIZES[@]}"
do
  # IPIP setting
  config_IPIP "Always"

  use_ipip="ipip"

  # Configure Calico
  restart_calico ${MTU}

  # Configure perf
  restart_perf "net-arm-thunderx2-04" "net-arm-thunderx2-02"

  echo "${HOST_TYPE} Crosshost Mtu: ${MTU} testing"
  test_perf "crosshost" ${TEST_TIME} ${MTU} "IPIP"

  test_wrk
  
  echo "${HOST_TYPE} node2pod Mtu: ${MTU} IPIP testing"
  test_node2pod "node2pod" ${TEST_TIME} ${MTU} "IPIP"


done

# IPIP diabled mtu size: 1500 <--> 9000
for MTU in "${MTU_WITHOUT_IPIP[@]}"
do
  # IPIP setting
  config_IPIP "CrossSubnet"

  use_ipip="noipip"

  # Configure Calico
  restart_calico ${MTU}

  # Configure perf
  restart_perf "net-arm-thunderx2-04" "net-arm-thunderx2-02"

  echo "${HOST_TYPE} Crosshost Mtu: ${MTU} testing"
  test_perf "crosshost" ${TEST_TIME} ${MTU} "noIPIP"

  test_wrk
  
  echo "${HOST_TYPE} node2pod Mtu: ${MTU} noIPIP testing"
  test_node2pod "node2pod" ${TEST_TIME} ${MTU} "noIPIP"

done
