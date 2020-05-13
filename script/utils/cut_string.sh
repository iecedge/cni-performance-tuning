#!/bin/bash

string="nginx-c78rt                     1/1     Running   0          4m16s   192.168.169.195   net-arm-thunderx2-04   <none>           <none>"
string2="nginx-c78rt                     1/1     Running   0          4m16s   192.168.169.195   net-arm-thunderx2-04   <none>           <none>"
OLD_IFS="$IFS"
IFS=" "
array=($string)
IFS="$OLD_IFS"

for var in ${array[@]}
do
  echo $var
done

echo "Get the IP addr of the pod:"
echo ${array[5]}

echo "Method2:    "
array2=(`echo $string | tr ' ' ' '`)

for var in ${array2[@]}
do
  echo $var
done
echo "Get the IP addr of the pod:"
echo ${array[5]}

function get_items(){
  
  echo "\$1:"$1
  echo "\$2:"$2

  #temp=$(eval echo \$$1)
  #echo "temp:  "$temp
  string=$1

  OLD_IFS="$IFS"
  IFS=" "
  array=($1)
  IFS="$OLD_IFS"

  #for var in ${array[@]}
  #do
  #   echo $var
  #done

  #echo "Get the item"
  #item_num=$((10#$2))
  #echo "item_num:"$item_num

  #return ${array[`expr $item_num`]}
  return ${array[5]}

}

pod_ip=$(get_items "$string2" 5)
echo ""
echo "pod ip:"$pod_ip

