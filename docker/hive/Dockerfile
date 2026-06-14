FROM apache/hive:3.1.3

USER root

RUN apt-get update -qq && \
    apt-get install -y -qq netcat-openbsd wget && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    rm -f "$HIVE_HOME"/lib/postgresql-9*.jar && \
    ln -s "$HADOOP_HOME"/share/hadoop/tools/lib/hadoop-aws-*.jar "$HIVE_HOME"/lib/ && \
    wget -q "https://repo1.maven.org/maven2/com/amazonaws/aws-java-sdk-bundle/1.11.271/aws-java-sdk-bundle-1.11.271.jar" \
        -P "$HIVE_HOME"/lib/ && \
    wget -q "https://repo1.maven.org/maven2/org/postgresql/postgresql/42.7.3/postgresql-42.7.3.jar" \
        -P "$HIVE_HOME"/lib/ && \
    mkdir -p /tmp/hive /tmp/hive-local && \
    chown hive:hive /tmp/hive /tmp/hive-local && \
    chmod 0777 /tmp/hive /tmp/hive-local

USER hive
