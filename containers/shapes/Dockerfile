# Use Docker's multi-stage build capability to create an image that contains RTI Shapes applications
FROM ubuntu AS shapes

ARG SHAPES_SRC=shapes_src

# /app will hold our installation files
WORKDIR /app

# Copy the binaries, QoS file, and launcher script
COPY ${SHAPES_SRC}/objs/x64Linux4gcc7.3.0 ./objs/x64Linux4gcc7.3.0
COPY ${SHAPES_SRC}/objs/armv8Linux4gcc7.3.0 ./objs/armv8Linux4gcc7.3.0
COPY ${SHAPES_SRC}/USER_QOS_PROFILES.xml ./USER_QOS_PROFILES.xml
COPY containers/shapes/run-shapes.sh ./

# Install helper programs
RUN apt-get update && apt-get -y install iproute2     \
                                         net-tools    \
                                         iputils-ping \
                                         tcpdump      \
                                         && chmod +x /app/run-shapes.sh \
                                                    /app/objs/x64Linux4gcc7.3.0/ShapeType_publisher \
                                                    /app/objs/armv8Linux4gcc7.3.0/ShapeType_publisher \
                                                    /app/objs/x64Linux4gcc7.3.0/ShapeType_subscriber \
                                                    /app/objs/armv8Linux4gcc7.3.0/ShapeType_subscriber

CMD ["/bin/sh", "-c", "ifconfig; sleep 5; exec /app/run-shapes.sh"]
