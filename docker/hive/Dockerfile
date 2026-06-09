FROM apache/hive:4.2.0

USER root

RUN microdnf install -y nmap-ncat && \
    microdnf clean all && \
    ln -s "$HADOOP_HOME"/share/hadoop/tools/lib/hadoop-aws-*.jar "$HIVE_HOME"/lib/ && \
    wget -q "https://repo1.maven.org/maven2/software/amazon/awssdk/bundle/2.42.25/bundle-2.42.25.jar" \
        -P "$HIVE_HOME"/lib/ && \
    wget -q "https://repo1.maven.org/maven2/org/postgresql/postgresql/42.7.3/postgresql-42.7.3.jar" \
        -P "$HIVE_HOME"/lib/

USER hive
