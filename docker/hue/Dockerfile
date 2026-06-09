FROM gethue/hue:latest

USER root

RUN for f in \
      /usr/share/hue/build/env/lib/python*/site-packages/TCLIService/ttypes.py \
      /usr/share/hue/apps/beeswax/gen-py/TCLIService/ttypes.py \
      /usr/share/hue/apps/impala/gen-py/TCLIService/ttypes.py; do \
        awk '{gsub(/'"'"'orientation'"'"', None, 0,/, "'"'"'orientation'"'"', None, None,")}1' "$f" > /tmp/ttypes_patched && \
        mv /tmp/ttypes_patched "$f" && \
        echo "Patched: $f"; \
    done && \
    sed -i 's/if operation_handle.hasResultSet and TFetchOrientation.FETCH_FIRST:/if operation_handle.hasResultSet:/' \
      /usr/share/hue/apps/beeswax/src/beeswax/server/hive_server2_lib.py && \
    echo "Patched: hive_server2_lib.py"

USER hue
