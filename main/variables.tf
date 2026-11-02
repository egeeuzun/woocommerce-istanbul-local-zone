variable "project" {
  type = string
}

variable "env" {
  type = string
}

variable "region" {
  type = string
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "az_count" {
  description = "Altyapının yayılacağı AZ sayısı. Her AZ kendi public/app/data subnet'ini, NAT gateway'ini ve app route table'ını alır."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 4
    error_message = "az_count en az 2 olmalı (ALB ve DB subnet group şartı), en fazla 4 destekleniyor (CIDR planı /24 dilimlere göre)."
  }
}

variable "db_name" {
  type    = string
  default = "wordpress"
}

variable "db_username" {
  type    = string
  default = "wp_admin"
}

variable "db_instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "create_read_replica" {
  description = "Diyagramdaki gibi ilk AZ'de read replica oluşturur."
  type        = bool
  default     = true
}

variable "db_multi_az" {
  description = "RDS Multi-AZ standby. Read replica okuma yükünü dağıtır ama otomatik failover vermez; asıl veritabanı HA'sı bununla gelir. Maliyeti instance'ı ikiye katlar. Açıkken master AZ'si sabitlenmez."
  type        = bool
  default     = false
}

variable "enable_vpn" {
  description = "Diyagramdaki Pritunl VPN sunucusunu ilk AZ'nin public subnet'ine kurar ve özel katmanlara yönetimsel erişim açar. Açmadan önce vpn_admin_cidrs doldurulmalı."
  type        = bool
  default     = false
}

variable "vpn_admin_cidrs" {
  description = "Pritunl yönetim konsoluna (443) erişebilecek CIDR'ler, ör. [\"203.0.113.4/32\"]. 0.0.0.0/0 reddedilir."
  type        = list(string)
  default     = []
}

variable "vpn_instance_type" {
  type    = string
  default = "t3.micro"
}

variable "vpn_wireguard_port" {
  description = "Pritunl sunucusundaki WireGuard portu; Pritunl bunu sunucu başına kendisi atar ve konsolda gösterir. Doğru değer girilmezse WireGuard bağlantıları kurulmaz. null = WireGuard portu açılmaz."
  type        = number
  default     = null
}

variable "vpn_ubuntu_codename" {
  description = "Pritunl sunucusunun Ubuntu sürümü. AMI aramasını ve apt suite'lerini birlikte belirler. 24.04 LTS = noble. 26.04 (resolute) için MongoDB henüz sunucu paketi yayınlamadı."
  type        = string
  default     = "noble"
}

variable "vpn_ami_id" {
  description = "Pritunl AMI'sini sabitler. Boş bırakılırsa deploy edilen bölgede vpn_ubuntu_codename ile eşleşen en güncel Canonical imajı kullanılır. AMI id'leri bölgeye özeldir: eu-west-1'deki bir id eu-central-1'de çalışmaz."
  type        = string
  default     = ""
}

variable "container_image" {
  description = "ECR disi bir imajla calismak icin override. Bos birakilirsa ecr modulunun urettigi repo ve image_tag kullanilir."
  type        = string
  default     = ""
}

variable "image_tag" {
  description = "ECR'dan cekilecek taban tag"
  type        = string
  default     = "latest"
}

variable "container_port" {
  description = "WordPress konteynerinin dinlediği port. ALB target group, ECS task ve ECS security group'a tek kaynaktan dağıtılır."
  type        = number
  default     = 80
}

variable "health_check_path" {
  description = "ALB target group saglik kontrolu yolu. Imajdaki /health.php WordPress'i yuklemez; / ise her kontrolde DB'ye gider ve kurulum oncesi 302 doner."
  type        = string
  default     = "/health.php"
}

variable "alb_ingress_cidrs" {
  description = "ALB'ye 80/443 erişimi olan CIDR blokları"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "desired_count" {
  type    = number
  default = 2
}

variable "enable_elasticache" {
  description = "Memcached object cache (ElastiCache). Istanbul Local Zone'da ElastiCache yok; iki ortami ayni uygulama mimarisiyle karsilastirmak icin kapatilabilir."
  type        = bool
  default     = true
}

variable "wp_admin_password" {
  description = "WordPress yonetici parolasi (admin). Bos = Terraform rastgele uretir. Imaj her task acilisinda parolayi bu degerle esitler; degistirmek task'lari yeniler."
  type        = string
  default     = ""
  sensitive   = true
}

variable "enable_auto_seed" {
  description = "Imaj acilista WordPress'i kurar ve seed'i calistirir (SHOP_AUTO_SEED=1, wordpress-shop-demo imaji); elle wp core install / seed gerekmez."
  type        = bool
  default     = true
}

variable "enable_ecs_exec" {
  description = "ECS Exec ile çalışan konteynere kabuk açmayı sağlar. Açmak yeni bir deployment tetikler (task'lar yenilenir) ve oturumlar CloudWatch'a kaydedilir."
  type        = bool
  default     = false
}

variable "enable_waf" {
  type    = bool
  default = true
}

variable "domain_name" {
  type    = string
  default = ""
}

variable "hosted_zone_id" {
  type    = string
  default = ""
}

variable "acm_certificate_arn_us_east_1" {
  description = "CloudFront icin us-east-1'deki ACM sertifikasi"
  type        = string
  default     = ""
}

variable "alb_certificate_arn" {
  description = "ALB icin bolgesel ACM sertifikasi"
  type        = string
  default     = ""
}

variable "enable_cicd" {
  type    = bool
  default = false
}

variable "codestar_connection_arn" {
  type    = string
  default = ""
}

variable "repository_id" {
  description = "Ornek: kullanici/wordpress-repo"
  type        = string
  default     = ""
}

variable "branch" {
  type    = string
  default = "main"
}

variable "admin_extra_allowed_cidrs" {
  description = "VPN'in Elastic IP'sine ek olarak yönetim paneline erişebilecek CIDR'ler. VPN çöktüğünde panele erişimi kaybetmemek için bir kaçış kapısı; boş bırakılırsa tek yol VPN olur."
  type        = list(string)
  default     = []
}

variable "restrict_alb_to_cloudfront" {
  description = "ALB'ye erişimi CloudFront edge'leriyle sınırlar. Kapatılırsa ALB adresi doğrudan çağrılarak CloudFront önündeki WAF (ve wp-admin IP kısıtı) baypas edilebilir."
  type        = bool
  default     = true
}

variable "static_bucket_versioning" {
  description = "Statik/medya bucket'inda versiyonlama. Yanlislikla silinen veya uzerine yazilan bir dosyayi geri almayi saglar; eski versiyonlar static_bucket_noncurrent_expiration_days sonunda temizlenir."
  type        = bool
  default     = true
}

variable "static_bucket_noncurrent_expiration_days" {
  description = "Guncel olmayan nesne versiyonlarinin saklanma suresi."
  type        = number
  default     = 30
}

variable "static_bucket_intelligent_tiering" {
  description = "Bucket'taki 128 KB ustu nesneleri INTELLIGENT_TIERING sinifina gecirir. WordPress medya kutuphaneleri cogunlukla kucuk thumbnail agirlikli oldugu icin varsayilan kapali; buyuk dosya agirlikli bir kutuphanede acmak kazandirir."
  type        = bool
  default     = false
}

variable "static_bucket_force_destroy" {
  description = "terraform destroy sirasinda bucket icindeki nesneleri de siler. Uretimde false yapilmali."
  type        = bool
  default     = true
}

variable "offload_uploads_to_s3" {
  description = "/wp-content/uploads/* isteklerini ALB yerine dogrudan S3 origin'ine yonlendirir. ECS'in medya trafigini tamamen ustunden alir ama yalnizca konteyner imajinda medyayi bu bucket'a yazan bir eklenti kuruluyken acilmali; aksi halde nesneler bucket'ta olmadigi icin gorseller 403 doner."
  type        = bool
  default     = false
}

variable "enable_plugin_installs" {
  description = "wp-admin uzerinden eklenti/tema kurulumunu acar. Acikken wp-content/plugins ve wp-content/themes EFS'ten mount edilir; kurulan dosyalar butun task'larda ayni ve deploy'lar arasinda kalici olur. Kapaliyken kod tamamen imajdan gelir (immutable deployment) ve panelden kurulum engellenir."
  type        = bool
  default     = false
}

variable "enable_efs" {
  description = "wp-content/uploads (ve enable_plugin_installs acikken plugins/themes) icin EFS. Kapatilirsa task'lar durumsuz olur: kod imajdan gelir, medya S3'e offload edilir. Bu yuzden kapatmak icin offload_uploads_to_s3 = true ve enable_plugin_installs = false olmali. EFS olmayan ortamlarla (Local Zone) karsilastirilabilir bir baseline icin kapali tutun. Calisan bir ortamda kapatmak EFS'i ve icindeki dosyalari siler."
  type        = bool
  default     = true
}

variable "media_remove_local" {
  description = "Medya S3'e offload edildikten sonra yerel (EFS) kopyasini siler. EFS'in medyayla buyumesini engeller; kapatilirsa dosya hem S3'te hem EFS'te durur."
  type        = bool
  default     = true
}

variable "data_residency" {
  description = "Veri tutan kaynaklara yazilan data-residency etiketi (ISO ulke kodu). Residency Guard bu etiketli kaynaklarin gercekte nerede durdugunu denetler; baseline'da kaynaklar Frankfurt'ta oldugu icin bulgu olarak gorunmeleri beklenir. Bos birakilirsa etiket yazilmaz."
  type        = string
  default     = "tr"
}
