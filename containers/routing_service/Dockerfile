# Use Docker's multi-stage build capability to create an image that contains rti routing service
FROM ubuntu AS routingservice

# /app will hold our installation files
WORKDIR /app

# Copy the library files and executable
COPY bin/ ./bin/
COPY qos/ ./qos/
COPY libs/ ./libs/
COPY run-routingservice.sh ./

# Install helper programs
RUN apt-get update && apt-get -y install iproute2     \
                                         net-tools    \
                                         iputils-ping \
                                         tcpdump      \
                                         && chmod +x /app/run-routingservice.sh

CMD ["/bin/sh", "-c", "ifconfig; sleep 5; exec /app/run-routingservice.sh"]
