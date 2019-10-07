# THIS CODE IS EXPERIMENTAL, USE THE DOCKER COMPOSE UP FOR A BETTER TESTED SOLUTION

# start elasticsearch database (can be accessed with an API using curl):
# The vm.max_map_count docker deamon configuration must be set on 262144.
docker run -d -p 9200:9200 -p 9300:9300 -e "discovery.type=single-node" elasticsearch:7.3.0

#docker run -d -p 24224:24224 -p 24224:24224/udp -v ./data:/fluentd/log fluent/fluentd:v1.3-debian-1
docker run -d -p 24224:24224 -v ./fluentd/:/fluentd/etc/ -e FLUENTD_CONF=in_docker.conf --log-driver=fluentd --log-opt fluentd-address=host.docker.internal:24224

# When using the log driver this simple, it logs to the `/fluentd/log/` folder to a file (by default).
# It is possible to obtain the logs that were procesed by running: `docker exec <container_ID> cat /fluentd/log/data.log`.
# To be sure this file exists, you could run a `ls` command to the folder in the same way.
#docker run -d -p 24224:24224 fluent/fluentd:v1.3-debian-1

# pipe 1
docker run -d --log-driver=fluentd                                            --env PROCESS_NAME=merging_results    --env PROCESS_VERSION=1.5.2 --env-file=.env multifunctionalprocess
docker run -d --log-driver=fluentd --log-opt fluentd-address=127.0.0.1:24224  --env PROCESS_NAME=merging_results    --env PROCESS_VERSION=1.5.2 --env-file=.env multifunctionalprocess
docker run -d --log-driver=fluentd --log-opt fluentd-address=172.17.0.2:24224 --env PROCESS_NAME=classification     --env PROCESS_VERSION=9.1.0 --env-file=.env multifunctionalprocess
docker run -d --log-driver=fluentd --log-opt fluentd-address=172.17.0.2:24224 --env PROCESS_NAME=classification     --env PROCESS_VERSION=1.0.0 --env-file=.env multifunctionalprocess
docker run -d --log-driver=fluentd --log-opt fluentd-address=172.17.0.2:24224 --env PROCESS_NAME=classification     --env PROCESS_VERSION=1.0.0 --env-file=.env multifunctionalprocess
docker run -d --log-driver=fluentd --log-opt fluentd-address=172.17.0.2:24224 --env PROCESS_NAME=assigner           --env PROCESS_VERSION=1.0.0 --env-file=.env multifunctionalprocess
docker run -d --log-driver=fluentd --log-opt fluentd-address=172.17.0.2:24224 --env PROCESS_NAME=uploader           --env PROCESS_VERSION=1.0.0 --env-file=.env multifunctionalprocess
																														      
# pipe 2  (contains configurations)                                                                                          
docker run -d --log-driver=fluentd --log-opt fluentd-address=172.17.0.2:24224 --env PROCESS_NAME=first_process      --env PROCESS_VERSION=1.9.2 --env-file=.env multifunctionalprocess
docker run -d --log-driver=fluentd --log-opt fluentd-address=172.17.0.2:24224 --env PROCESS_NAME=second_process     --env PROCESS_VERSION=2.2.0 --env-file=.env multifunctionalprocess
docker run -d --log-driver=fluentd --log-opt fluentd-address=172.17.0.2:24224 --env PROCESS_NAME=third_process      --env PROCESS_VERSION=5.3.0 --env-file=.env multifunctionalprocess

# pipe 4
docker run -d --log-driver=fluentd --log-opt fluentd-address=172.17.0.2:24224 --env PROCESS_NAME=sumarizing_results --env PROCESS_VERSION=1.5.2 --env-file=.env multifunctionalprocess
docker run -d --log-driver=fluentd --log-opt fluentd-address=172.17.0.2:24224 --env PROCESS_NAME=creating_report    --env PROCESS_VERSION=1.0.0 --env-file=.env multifunctionalprocess

