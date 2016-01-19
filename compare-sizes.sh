#!/usr/bin/env sh

set -x # print each command
set -e # fail fast

result_dir="result`date +%Y-%m-%d_%H_%M_%S`"
mkdir $result_dir
echo results in $result_dir

for compressor in '' 'LZ4Compressor' 'SnappyCompressor' 'DeflateCompressor' ; do
  for profile in *.yaml ; do
    # kill cassandra ; from mshuler
    while pgrep -f CassandraDaemon; do
      pkill -f CassandraDaemon
      echo "SIGTERM sent"
      sleep 2
    done
    echo "no CassandraDaemon"

    stamp="`date +%Y-%m-%d_%H_%M_%S`"
    compressor_id_string="${compressor:-no_compressor}"
    profile_id_string="`basename $profile .yaml`"

    if [ "$compressor" != '' ] ; then
      compressor_with_append="AND compression = { 'class': $compressor }"
    else
      compressor_with_append="AND compression = { 'enabled': false }"
    fi

    (
      ccm create "with-${compressor_id_string}_${profile_id_string}_${stamp}" -n 1 -v "${CASSANDRA_VERSION:-3.2}"
      ccm start --wait-for-binary-proto

      echo "CREATE KEYSPACE stresscql WITH
            replication = {'class': 'SimpleStrategy', 'replication_factor': 3};" | ccm node1 cqlsh
      echo "CREATE TABLE blogposts (
              domain text,
              published_date timeuuid,
              url text,
              author text,
              title text,
              body text,
              PRIMARY KEY(domain, published_date)
            ) WITH CLUSTERING ORDER BY (published_date DESC)
                   AND compaction = { 'class':'LeveledCompactionStrategy' }
                   AND comment='A table to hold blog posts'
                   $compressor_with_append ;
           " | ccm node1 cqlsh


     ccm stress user profile=./$profile ops\(insert=1\)
      ccm node1 nodetool flush
      ccm node1 nodetool cfstats keyspace1
      ccm node1 nodetool compact
      ccm node1 nodetool cfstats keyspace1
      ccm stop
    ) | tee "$result_dir"/"results_${compressor_id_string}_${stamp}"
    ( ccm stop ) # stop in a subshell so it can fail

  done
done

echo results in $result_dir
