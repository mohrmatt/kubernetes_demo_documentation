FROM ubuntu:20.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
	build-essential \
	ca-certificates \
	gcc-aarch64-linux-gnu \
	g++-aarch64-linux-gnu \
	make \
	rsync \
	&& rm -rf /var/lib/apt/lists/*

# Mount your app sources at /work/src
# Mount RTI Connext at /opt/rti (e.g., /home/<user>/rti_connext_dds-7.3.0)
WORKDIR /work/src

ENV RTI_HOME=/opt/rti
ENV NDDSHOME=/opt/rti
ENV PATH="$RTI_HOME/bin:$PATH"

CMD ["/bin/bash"]
