FROM mysql:8.0

# Copy custom MySQL configuration if needed
COPY my.cnf /etc/mysql/conf.d/

# Copy initialization scripts
COPY init.sql /docker-entrypoint-initdb.d/

# Expose MySQL port
EXPOSE 3306

# MySQL will use the default entrypoint from the base image
