# Usar Debian 12 como imagen base
FROM debian:bookworm-slim

# Establecer variables de entorno necesarias para no tener que confirmar la instalación
ENV DEBIAN_FRONTEND=noninteractive

# Actualizar e instalar las dependencias necesarias
RUN apt update && apt -y upgrade && \
    apt install -y postgresql python3-certbot-nginx certbot net-tools procps postgresql-contrib vim wget build-essential python3-dev python3-venv python3-wheel \
    libfreetype6-dev libxml2-dev libzip-dev libldap2-dev libsasl2-dev python3-setuptools \
    node-less libjpeg-dev zlib1g-dev libpq-dev libxslt1-dev libldap2-dev libtiff5-dev \
    libopenjp2-7-dev liblcms2-dev libwebp-dev libharfbuzz-dev libfribidi-dev libxcb1-dev  \
    git nginx

# Crear usuario del sistema odoo
RUN useradd -m -s /bin/bash odoo && \
    echo 'odoo:odoo' | chpasswd && \
    adduser odoo sudo

# Configurar PostgreSQL y crear el usuario de Odoo
RUN service postgresql start && \
    su - postgres -c "psql -c \"CREATE USER root WITH SUPERUSER PASSWORD 'root';\"" && \
	su - postgres -c "psql -c \"CREATE USER odoo WITH SUPERUSER PASSWORD 'odoo';\""

# Descargar e instalar multiarch-support
RUN wget http://archive.ubuntu.com/ubuntu/pool/main/g/glibc/multiarch-support_2.27-3ubuntu1_amd64.deb && \
    apt-get install -y ./multiarch-support_2.27-3ubuntu1_amd64.deb

# Descargar e instalar libjpeg-turbo
RUN wget http://mirrors.kernel.org/ubuntu/pool/main/libj/libjpeg-turbo/libjpeg-turbo8_2.1.2-0ubuntu1_amd64.deb && \
    apt install -y ./libjpeg-turbo8_2.1.2-0ubuntu1_amd64.deb

# Descargar e instalar wkhtmltopdf
RUN wget https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox_0.12.6.1-2.jammy_amd64.deb && \
    apt install -y ./wkhtmltox_0.12.6.1-2.jammy_amd64.deb && \
    apt-get install -f -y

RUN apt-get install python3-m2crypto
# Crear directorio para custom addons
RUN mkdir -p /opt/odoo/odoo-custom-addons

# Clonar Odoo
RUN git clone https://github.com/odoo/odoo.git --depth 1 --branch 16.0 /opt/odoo/odoo

# Clona pack de herramientas dbfilter autoback etc
RUN git clone https://github.com/OCA/server-tools.git /opt/odoo/odoo-custom-addons/server-tools
RUN ln -s /opt/odoo/odoo-custom-addons/server-tools/dbfilter_from_header /opt/odoo/odoo-custom-addons/dbfilter_from_header

# Crear entorno virtual e instalar dependencias de Odoo
RUN python3 -m venv /opt/odoo/odoo-venv && \
    /opt/odoo/odoo-venv/bin/pip install wheel && \
    /opt/odoo/odoo-venv/bin/pip install -r /opt/odoo/odoo/requirements.txt



# FActuracion 
RUN git clone https://github.com/a2systems/odoo-argentina.git  /opt/odoo/odoo-custom-addons/odoo-argentina --branch 16.0
RUN ln -s /opt/odoo/odoo-custom-addons/odoo-argentina/* /opt/odoo/odoo-custom-addons

RUN /opt/odoo/odoo-venv/bin/pip install -r /opt/odoo/odoo-custom-addons/odoo-argentina/requirements.txt 

#Arregl BUG de afip por version de python mas nueva 
RUN sed -i 's/getargspec/getfullargspec/g' /opt/odoo/odoo-venv/lib/python3.11/site-packages/pysimplesoap/transport.py

#Crea Cache
RUN mkdir /opt/odoo/odoo-venv/lib/python3.11/site-packages/pyafipws/cache
RUN chown -R 777 /opt/odoo/odoo-venv/lib/python3.11/site-packages/pyafipws/cache
# Arreglar por error de ususario , validar si funciona 
RUN sed -i 's/CipherString = DEFAULT@SECLEVEL=2/CipherString = DEFAULT@SECLEVEL=1/' /etc/ssl/openssl.cnf
#RUN chown -R odoo:odoo /opt/odoo/sources

# Crear un enlace simbólico en /opt/odoo/odoo-custom-addons/ que apunte a /opt/odoo/odoo-custom-addons/dbfilter-from-header
RUN ln -s /opt/odoo/odoo-custom-addons/server-tools/dbfilter_from_header /opt/odoo/odoo-custom-addons/dbfilter_from_header

# Crear archivo de configuración de Odoo
RUN echo "[options]\n\
admin_passwd = MiPasswordSuperSeguro\n\
db_host = False\n\
db_port = False\n\
db_user = False\n\
db_password = False\n\
proxy_mode = True\n\
logfile = /var/log/odoo/odoo.log\n\
addons_path = /opt/odoo/odoo/addons,/opt/odoo/odoo-custom-addons" > /etc/odoo.conf

# Crear archivo de configuración de Nginx
RUN echo "server {\n\
    listen 8080;\n\
    server_name localhost;\n\
    location / {\n\
        proxy_pass http://localhost:8069;\n\
		client_max_body_size 400M;\n\
        proxy_set_header Host \$host;\n\
        proxy_set_header X-Real-IP \$remote_addr;\n\
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;\n\
        proxy_set_header X-Forwarded-Proto \$scheme;\n\
        proxy_set_header Upgrade \$http_upgrade;\n\
        proxy_set_header Connection 'upgrade';\n\
        proxy_cache_bypass \$http_upgrade;\n\
    }\n\
}" > /etc/nginx/sites-available/default

# Crear script de inicio
RUN echo "#!/bin/bash\n\
# Iniciar PostgreSQL\n\
/etc/init.d/postgresql start\n\
\n\
# Esperar a que PostgreSQL esté completamente disponible\n\
echo 'Esperando a que PostgreSQL esté listo...'\n\
until pg_isready -q; do\n\
    sleep 1\n\
done\n\
\n\
# Iniciar Odoo\n\
echo 'Iniciando Odoo...'\n\
/opt/odoo/odoo-venv/bin/python3 /opt/odoo/odoo/odoo-bin -c /etc/odoo.conf &\n\
\n\
# Iniciar Nginx\n\
echo 'Iniciando Nginx...'\n\
nginx -g 'daemon off;'\n\
" > /entrypoint.sh

RUN chmod +x /entrypoint.sh

# Exponer los puertos
EXPOSE 8080 80 443

# Definir el punto de entrada
ENTRYPOINT ["/entrypoint.sh"]
 
