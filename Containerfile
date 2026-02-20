FROM alpine:latest

RUN apk add --no-cache socat python3 bash

ADD https://gist.githubusercontent.com/0x1e02/12a97ca87321a0fd30f12e3a260354bb/raw/9f5aa12c052ce2eeba323c29239a1cadeeda5506/socar.sh /socar.sh

RUN chmod +x /socar.sh

ENTRYPOINT ["/socar.sh"]
