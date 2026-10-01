# The maintenance poller (deploy/maintenance.sh): POSTs the API's
# maintenance endpoints on a schedule.
FROM alpine:3.22
RUN apk add --no-cache curl tini
COPY deploy/maintenance.sh /usr/local/bin/maintenance.sh
RUN chmod 0755 /usr/local/bin/maintenance.sh
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/maintenance.sh"]
