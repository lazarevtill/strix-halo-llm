# Sandboxed eval image: deps installed at BUILD time, so the scoring container can run with
# --network none (no exfiltration) yet still import third-party packages a model solution
# might need.
FROM python:3.12-slim

# Package index is a build ARG -- public by default. Behind a private mirror:
#   docker build -t coding-eval . --build-arg PIP_INDEX_URL=https://<nexus-host>/repository/pypi-proxy/simple
ARG PIP_INDEX_URL=https://pypi.org/simple
ENV PIP_INDEX_URL=${PIP_INDEX_URL} \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1

# common pure-python + numeric deps a coding task might import
RUN pip install --no-cache-dir --root-user-action=ignore \
        pytest sortedcontainers cachetools numpy

# drop root for the isolated run
RUN useradd -m -u 1000 sandbox
USER sandbox
WORKDIR /work
