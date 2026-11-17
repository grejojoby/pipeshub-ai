# App module. Build this on top of the published image.
#
# The base image is the stable module and is not rebuilt here:
#   Python packages            ~3.3GB
#   Hugging Face models        ~1.3GB
#   Playwright browsers        ~713MB
#   LibreOffice and OS libs    ~1GB
#   NLTK and fastembed         ~70MB
#   Node modules and Node.js   ~1GB
#
# This image only replaces application files, so a deploy reuses every
# heavy layer already on the server.
ARG BASE_IMAGE=pipeshubai/pipeshub-ai:latest
FROM ${BASE_IMAGE}

COPY connector.py /app/python/app/connectors/sources/salesforce/connector.py
COPY router.py /app/python/app/connectors/api/router.py
COPY neo4j_provider.py /app/python/app/services/graph_db/neo4j/neo4j_provider.py
COPY public/ /app/backend/dist/public/

ARG GIT_COMMIT=""
ENV GIT_COMMIT=${GIT_COMMIT}
