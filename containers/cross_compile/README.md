# Cross-Compile Container

Use this container when you need to update and rebuild the Shapes application binaries from `shapes_src/`.

Note: This cross-compile container is used to build ARM-target binaries.

## Build the cross-compile container

Run from the `containers/cross_compile` directory:

```bash
docker build -t cross_compile -f Dockerfile .
```

## Run the cross-compile container

Set your host paths before running:

- `REPO_ROOT`: absolute path to this repository
- `RTI_INSTALL_DIR`: absolute path to your RTI Connext DDS installation directory

Then run:

```bash
docker run --rm -it \
  -v ${REPO_ROOT}/shapes_src:/work/src \
  -v ${RTI_INSTALL_DIR}:/opt/rti \
  --name cross_compile \
  cross_compile
```

The `cross_compile` image is a local build tool and does not need to be pushed to the local registry.
