FROM alpine:latest

RUN apk add --no-cache socat python3 bash

COPY ./socar.sh

RUN chmod +x /socar.sh

ENTRYPOINT ["/socar.sh"]
