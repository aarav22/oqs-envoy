# Building Envoy with Post-Quantum Cryptography (OQS-BoringSSL)

This guide shows how to build Envoy with quantum-safe cryptography support using OQS-BoringSSL.

## Quick Start
[DockerHub](https://hub.docker.com/r/aaravvar/oqs-envoy)
```bash
docker pull aaravvar/oqs-envoy:latest
```

## Prerequisites

```bash
# Install basic dependencies
sudo apt update
sudo apt install \
   autoconf \
   curl \
   libtool \
   patch \
   python3-pip \
   unzip \
   virtualenv \
   cmake \
   ninja-build \
   git \
   build-essential

# Install LLVM 20.1.0
cd ~/
wget https://github.com/llvm/llvm-project/releases/download/llvmorg-20.1.0/LLVM-20.1.0-Linux-X64.tar.xz
tar -xf LLVM-20.1.0-Linux-X64.tar.xz

# Install Bazelisk as Bazel
sudo wget -O /usr/local/bin/bazel https://github.com/bazelbuild/bazelisk/releases/latest/download/bazelisk-linux-amd64
sudo chmod +x /usr/local/bin/bazel
```

## Setup Envoy

```bash
# Clone Envoy
git clone https://github.com/envoyproxy/envoy.git
cd envoy
git checkout tags/v1.35.0

# Setup Clang configuration
bazel/setup_clang.sh $(pwd)/../LLVM-20.1.0-Linux-X64

# Add warning suppressions to user.bazelrc
cat > user.bazelrc << 'EOF'
build --config=clang
build --copt=-Wno-nullability-completeness
build --copt=-Wno-error=nullability-completeness
build --copt=-Wno-deprecated-literal-operator
build --copt=-Wno-error=deprecated-literal-operator
build --host_copt=-Wno-nullability-completeness
build --host_copt=-Wno-error=nullability-completeness
build --host_copt=-Wno-deprecated-literal-operator
build --host_copt=-Wno-error=deprecated-literal-operator
EOF
```

## Build liboqs

```bash
cd ..
git clone --depth 1 https://github.com/open-quantum-safe/liboqs.git
cd liboqs
mkdir build && cd build

cmake -GNinja \
  -DCMAKE_INSTALL_PREFIX=/usr/local \
  -DOQS_USE_OPENSSL=OFF \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  ..

ninja
sudo ninja install
cd ../../
```

## Build OQS-BoringSSL

```bash
git clone https://github.com/open-quantum-safe/boringssl.git oqs-boringssl
cd oqs-boringssl

# Link to liboqs installation
ln -sf /usr/local oqs

mkdir build && cd build
cmake -GNinja -DCMAKE_BUILD_TYPE=Release ..
ninja

# Create directory structure for Envoy
cd ../../envoy
mkdir -p oqs-deps/boringssl/{lib,include}

# Copy build artifacts
cp ../oqs-boringssl/build/ssl/libssl.a oqs-deps/boringssl/lib/
cp ../oqs-boringssl/build/crypto/libcrypto.a oqs-deps/boringssl/lib/
cp /usr/local/lib/liboqs.a oqs-deps/boringssl/lib/
cp -r ../oqs-boringssl/include/* oqs-deps/boringssl/include/
```

## Configure Envoy to Use OQS-BoringSSL

Add this to your `WORKSPACE` file, **before** the `envoy_dependencies()` line:

```python
new_local_repository(
    name = "boringssl",
    path = "oqs-deps/boringssl",
    build_file_content = """
load("@rules_cc//cc:defs.bzl", "cc_library")

cc_library(
    name = "crypto",
    srcs = [
        "lib/libcrypto.a",
        "lib/liboqs.a",
    ],
    hdrs = glob([
        "include/**/*.h",
    ]),
    includes = ["include"],
    linkopts = ["-pthread", "-lm", "-ldl"],
    visibility = ["//visibility:public"],
)

cc_library(
    name = "ssl",
    srcs = ["lib/libssl.a"],
    hdrs = glob([
        "include/**/*.h", 
    ]),
    includes = ["include"],
    deps = [":crypto"],
    linkopts = ["-pthread"],
    visibility = ["//visibility:public"],
)

cc_library(
    name = "boringssl", 
    deps = [":ssl", ":crypto"],
    visibility = ["//visibility:public"],
)
""",
)
```

## Build Envoy

```bash
# Clean and build
bazel clean --expunge
bazel build -c opt //source/exe:envoy-static --jobs=80

# Verify quantum-safe algorithms are included
strings bazel-bin/source/exe/envoy-static | grep -i mlkem
```

## Setup Testing Environment

### Install OQS-provider for OpenSSL

```bash
cd ..

# Build liboqs for OpenSSL (separate from BoringSSL version)
git clone --depth 1 https://github.com/open-quantum-safe/liboqs.git liboqs-openssl
cd liboqs-openssl
mkdir build && cd build

cmake -GNinja \
  -DCMAKE_INSTALL_PREFIX=/usr/local \
  -DOQS_USE_OPENSSL=ON \
  -DCMAKE_BUILD_TYPE=Release \
  ..

ninja
sudo ninja install

# Build OQS-provider
cd ../../
git clone --depth 1 https://github.com/open-quantum-safe/oqs-provider.git
cd oqs-provider
mkdir build && cd build

cmake -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr/local \
  ..

make -j$(nproc)
sudo make install
cd ../../envoy
```

### Configure OpenSSL

```bash
# Create OpenSSL config
cat > openssl-oqs.cnf << 'EOF'
openssl_conf = openssl_init

[openssl_init]
providers = provider_sect

[provider_sect]
default = default_sect
oqs = oqs_sect

[default_sect]
activate = 1

[oqs_sect]
activate = 1
module = /usr/local/lib/oqsprovider.so
EOF

export OPENSSL_CONF=$(pwd)/openssl-oqs.cnf

# Verify OQS-provider works
openssl list -providers
openssl list -kem-algorithms -provider oqs | grep -i mlkem
```

## Test Quantum-Safe Envoy

### Create Test Configuration

```bash
# Generate test certificate
openssl req -x509 -newkey rsa:2048 -keyout test-key.pem -out test-cert.pem -days 365 -nodes -subj "/CN=localhost"

# Create Envoy config with ML-KEM support
cat > test-mlkem.yaml << 'EOF'
static_resources:
  listeners:
  - name: listener_0
    address:
      socket_address:
        address: 127.0.0.1
        port_value: 10443
    filter_chains:
    - transport_socket:
        name: envoy.transport_sockets.tls
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.DownstreamTlsContext
          common_tls_context:
            tls_certificates:
            - certificate_chain:
                filename: "test-cert.pem"
              private_key:
                filename: "test-key.pem"
            tls_params:
              ecdh_curves: ["mlkem1024", "p521_mlkem1024", "X25519"]
      filters:
      - name: envoy.filters.network.http_connection_manager
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
          stat_prefix: ingress_http
          route_config:
            name: local_route
            virtual_hosts:
            - name: local_service  
              domains: ["*"]
              routes:
              - match:
                  prefix: "/"
                direct_response:
                  status: 200
                  body:
                    inline_string: "🔐 Quantum-Safe Envoy with ML-KEM 1024!\n"
          http_filters:
          - name: envoy.filters.http.router
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router

admin:
  address:
    socket_address:
      address: 127.0.0.1
      port_value: 9901
EOF
```

### Run Tests

```bash
# Start Envoy
bazel-bin/source/exe/envoy-static --config-path test-mlkem.yaml &

# Test with quantum-safe curl
curl -v -k https://localhost:10443/ --curves mlkem1024

# Test with OpenSSL s_client
echo "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n" | \
openssl s_client -connect localhost:10443 -groups mlkem1024

# Look for "Server Temp Key: mlkem1024" in the output
```

## Success Indicators

✅ **Build Success**: `bazel build` completes without errors  
✅ **Quantum Algorithms**: `strings bazel-bin/source/exe/envoy-static | grep -i mlkem` shows results  
✅ **Config Validation**: `bazel-bin/source/exe/envoy-static --config-path test-mlkem.yaml --mode validate` passes  
✅ **TLS Handshake**: curl shows `Server Temp Key: mlkem1024`  
✅ **Response**: HTTP response contains "Quantum-Safe Envoy"  

You now have Envoy with post-quantum cryptography support! 🎉🔐
