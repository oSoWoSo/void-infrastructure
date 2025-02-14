job "mirror" {
  type = "system"
  datacenters = ["VOID-MIRROR"]
  namespace = "mirror"

  group "services" {
    network {
      mode = "bridge"
      port "http" { to = 80 }
      port "rsync" {
        to = 873
        static = 873
      }
    }

    volume "dist-mirror" {
      type = "host"
      source = "dist_mirror"
      read_only = true
    }

    task "nginx" {
      driver = "docker"

      vault {
        policies = ["void-secrets-traefik"]
      }

      config {
        image = "ghcr.io/void-linux/infra-nginx:20221230RC01"
        network_mode = "host"
      }

      volume_mount {
        volume = "dist-mirror"
        destination = "/srv/www"
      }

      template {
        data =<<EOF
{{- with secret "secret/lego/data/certificates/_.voidlinux.org.crt" -}}
{{.Data.contents}}
{{- end -}}
EOF
        destination = "secrets/certs/voidlinux.org.crt"
        perms = 400
      }

      template {
        data =<<EOF
{{- with secret "secret/lego/data/certificates/_.voidlinux.org.key" -}}
{{.Data.contents}}
{{- end -}}
EOF
        destination = "secrets/certs/voidlinux.org.key"
        perms = 400
      }

      template {
        data = <<EOF
server {
    include /etc/nginx/fragments/ssl.conf;
    listen 443 ssl http2 default_server;
    listen [::]:443 ssl http2 default_server;
    server_name _;
    return 400;
}
EOF
        destination = "local/nginx/00-default.conf"
      }

      template {
        data = <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    return 301 https://$host$request_uri;
}
EOF
        destination = "local/nginx/ssl_redirect.conf"
      }

      template {
        data = <<EOF
server {
    include /etc/nginx/fragments/ssl.conf;
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name repo-default.voidlinux.org
                repo-de.voidlinux.org
                repo-fi.voidlinux.org
                repo-us.voidlinux.org
                repo-fastly.voidlinux.org
                "~^repo-[a-z]{2}\.voidlinux\.org$";
    root /srv/www;

    location / {
        autoindex on;
    }

    location ~* \.(?:xbps|sig|iso|gz|xz)$ {
        expires 1y;
        add_header Cache-Control "public";
    }
}
EOF
        destination = "local/nginx/mirror.conf"
      }

      template {
        data = <<EOF
{{ range services -}}
{{ range service (printf "%s~_agent" .Name) -}}
{{ if index .ServiceMeta "nginx_enable" -}}
{{ if not (scratch.Key .Name) -}}
{{ scratch.Set .Name "1" -}}
server {
    include /etc/nginx/fragments/ssl.conf;
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name {{ index .ServiceMeta "nginx_names" }};

    location / {
        proxy_set_header Host $host;
        proxy_pass http://{{ .Address }}:{{ .Port }};
    }
}
{{ end -}}
{{ end -}}
{{ end -}}
{{ end -}}
EOF
        destination = "local/nginx/proxy.conf"
        change_mode = "signal"
        change_signal = "SIGHUP"
      }
    }

    task "rsync" {
      driver = "docker"

      config {
        image = "ghcr.io/void-linux/infra-rsync:v20210926rc01"
        volumes = ["local/voidmirror.conf:/etc/rsyncd.conf.d/voidmirror.conf"]
      }

      volume_mount {
        volume = "dist-mirror"
        destination = "/srv/rsync"
      }

      template {
        data = <<EOF
[voidlinux]
comment = Main Void Repository
path = /srv/rsync
read only = yes
list = yes
transfer logging = true
timeout = 600
exclude = - .* - *-repodata.* - *-stagedata.*
EOF
        destination = "local/voidmirror.conf"
      }
    }
  }
}
