# Use Docker's multi-stage build capability to create an image that contains rti cloud discovery service
FROM ubuntu as clouddiscoveryservice

# /app will hold our installation files
WORKDIR /app

# Copy the library files and executable
COPY bin/ ./bin/
COPY qos/ ./qos/
COPY libs/ ./libs/
COPY run-cds.sh ./

# Install helper programs
RUN apt-get update && apt-get -y install iproute2     \
                                         net-tools    \
                                         iputils-ping \
                                         tcpdump      \
                                         && chmod +x /app/run-cds.sh

CMD ["/bin/sh", "-c", "ifconfig; sleep 5; exec /app/run-cds.sh"]