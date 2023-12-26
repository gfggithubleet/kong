#!/bin/bash

echo "=============== benchmark(github routes) ==============="

echo ">>> traditional_compatible"
make bench ROUTER=traditional_compatible YAML=kong-default-github.yaml SCRIPT=path-github.lua WARMUP_URL=http://localhost:8000/repos/owner/repo/pages/health

echo ">>> radix"
make bench ROUTER=radix YAML=kong-radix-github.yaml SCRIPT=path-github.lua WARMUP_URL=http://localhost:8000/repos/owner/repo/pages/health



echo ""
echo ""
echo "=============== benchmark(10000 routes) ==============="

echo ">>> traditional_compatible"
make bench ROUTER=traditional_compatible YAML=kong-default-variable-10000.yaml SCRIPT=path-variable.lua WARMUP_URL=http://localhost:8000/user1/foo

echo ">>> radix"
make bench ROUTER=radix YAML=kong-radix-variable-10000.yaml SCRIPT=path-variable.lua WARMUP_URL=http://localhost:8000/user1/foo

echo ""
echo ""
echo "=============== benchmark(20000 routes) ==============="

echo ">>> traditional_compatible"
make bench ROUTER=traditional_compatible YAML=kong-default-variable-20000.yaml SCRIPT=path-variable.lua WARMUP_URL=http://localhost:8000/user1/foo

echo ">>> radix"
make bench ROUTER=radix YAML=kong-radix-variable-20000.yaml SCRIPT=path-variable.lua WARMUP_URL=http://localhost:8000/user1/foo

echo ""
echo ""
echo "=============== benchmark(30000 routes) ==============="

echo ">>> traditional_compatible"
make bench ROUTER=traditional_compatible YAML=kong-default-variable-30000.yaml SCRIPT=path-variable.lua WARMUP_URL=http://localhost:8000/user1/foo

echo ">>> radix"
make bench ROUTER=radix YAML=kong-radix-variable-30000.yaml SCRIPT=path-variable.lua WARMUP_URL=http://localhost:8000/user1/foo


echo ""
echo ""
echo "=============== benchmark(100000 routes) ==============="

echo ">>> traditional_compatible"
make bench ROUTER=traditional_compatible YAML=kong-default-variable-100000.yaml SCRIPT=path-variable.lua WARMUP_URL=http://localhost:8000/user1/foo

echo ">>> radix"
make bench ROUTER=radix YAML=kong-radix-variable-100000.yaml SCRIPT=path-variable.lua WARMUP_URL=http://localhost:8000/user1/foo

