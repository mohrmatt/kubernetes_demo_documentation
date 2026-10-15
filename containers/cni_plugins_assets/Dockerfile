FROM docker.io/library/alpine:3.20

# Package the offline CNI plugin archives inside the image so every node can
# extract the correct architecture tarball without host-level bootstrap copies.
COPY _offline_assets/cni-plugins/cni-plugins-linux-amd64-v1.4.0.tgz /opt/cni-plugins/
COPY _offline_assets/cni-plugins/cni-plugins-linux-arm64-v1.4.0.tgz /opt/cni-plugins/
COPY _offline_assets/cni-plugins/cni-plugins-linux-arm-v1.4.0.tgz /opt/cni-plugins/
