CA_FILES=./build/certs/ca.csr ./build/certs/ca.pem ./build/certs/ca-key.pem
SERVER_CERT_FILES=./build/certs/server.csr ./build/certs/server.pem ./build/certs/server-key.pem

all: build-certs

setup:
	go install github.com/cloudflare/cfssl/cmd/cfssl
	go install github.com/cloudflare/cfssl/cmd/cfssljson
	go install sigs.k8s.io/kustomize/kustomize/v3

clean:
	rm -rf build

build-manifests: $(SERVER_CERT_FILES)
	mkdir -p build
	kustomize build upstream -o build/install.yaml

build-certs: $(SERVER_CERT_FILES)

$(CA_FILES): ./certs/csr.json
	mkdir -p build/certs
	cfssl gencert -initca certs/csr.json | cfssljson -bare ./build/certs/ca

$(SERVER_CERT_FILES): $(CA_FILES) ./certs/ca-config.json ./certs/server.json
	cfssl gencert -ca=build/certs/ca.pem -ca-key=build/certs/ca-key.pem -config=certs/ca-config.json -profile=server certs/server.json | cfssljson -bare build/certs/server

.PHONY: setup clean build-manifests build-certs
