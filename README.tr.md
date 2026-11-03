# terraform-aws-wordpress-ha

[English](README.md) · **Türkçe**

> **İlk kez mi kuruyorsunuz?** Adım adım [çalıştırma kılavuzu](docs/calistirma-kilavuzu.md)
> sizi boş bir AWS hesabından çalışan bir mağazaya, sonra da tekrar sıfır
> maliyete götürür.

AWS üzerinde bir WooCommerce mağazası için Terraform kodu ve bu mağazayı müşteri
verisi Türkiye'de kalsın diye **Frankfurt**'tan **AWS İstanbul Local Zone**'a
taşıma projesi.

Mağaza, [wordpress-shop-demo](https://github.com/egeeuzun/wordpress-shop-demo)
reposundaki *Yerel Market* adlı sahte bir market. Müşterileri, siparişleri ve
T.C. kimlik numaraları uydurma, ama gerçeğine benziyor; böylece kişisel verinin
nereye gittiğini takip edebiliyoruz.

## Bir dakikada fikir

Local Zone, bir AWS bölgesinin başka bir şehre konmuş küçük bir parçasıdır.
İstanbul Local Zone (`eu-central-1-ist-1a`) Frankfurt bölgesine bağlıdır, ama
sunucuları ve diskleri fiziksel olarak İstanbul'dadır.

Plan basit: mağazayı ve veritabanını İstanbul'daki sunucularda çalıştırmak,
Frankfurt'ta yalnızca müşteri verisi olmayan şeyleri tutmak.

Püf noktası: Local Zone, AWS servislerinin yalnızca bir kısmını sunar. EC2
sunucuları, EBS diskleri, S3 (One Zone-IA), load balancer'lar ve ECS var. RDS,
Fargate, EFS ve ElastiCache **yok**. Eksik her servisin yerine kendimiz
çalıştırdığımız bir karşılık gerekiyor.

## Bugün: her şey Frankfurt'ta

```
Müşteri ──► CloudFront + WAF ──► Load balancer ──► ECS Fargate'te WordPress (2 AZ)
                 │                                   ├── RDS MariaDB (yönetilen veritabanı)
                 │                                   └── ElastiCache (cache, varsayılan kapalı)
                 └── /wp-content/uploads ──► S3 bucket (ürün görselleri)

Hepsi Frankfurt'ta (eu-central-1).
```

Bu `envs/frankfurt-baseline`. Karşılaştırma yaptığımız "önce" hali. Uygulama
tarafı `envs/istanbul-lz` ile aynı, yani fark konumdan ve platformdan (Fargate,
RDS) geliyor: aynı imaj ve `image_tag`, aynı otomatik kurulum ve seed, EFS yok,
object cache yok, read replica yok (ikisi de `enable_elasticache` ve
`create_read_replica` ile açılabilir) ve aynı CloudFront fiyat sınıfı.

## Hedef: İstanbul Local Zone

Bu `envs/istanbul-lz`.

```
Türkiye'deki müşteri
   │
   ▼
CloudFront + WAF            (CloudFront'un İstanbul'da edge'i var)
   │
   ▼
Load balancer               ┐
   │                        │
   ▼                        │  İstanbul Local Zone
ECS'te WordPress, EC2       │  (eu-central-1-ist-1a)
   └── EC2 + EBS'te MariaDB │
       └── gecelik EBS      │
           snapshot'ları    ┘

Hâlâ Frankfurt'ta: ürün görselleri (S3), Local Zone'un internete çıktığı
NAT gateway, container registry (ECR), secret'lar (SSM), Terraform state
ve AWS yönetim API'leri.
```

İlk sürüm bilerek basit tutuldu. Frankfurt'ta olmaması gereken bazı şeyler hâlâ
orada (bkz. [Hâlâ Frankfurt'ta olanlar](#hâlâ-frankfurtta-olanlar)). Bunları
bulmak projenin bir sonraki adımı.

### Ne değişiyor, neden

| Parça | Bugün Frankfurt | İstanbul Local Zone | Neden |
| --- | --- | --- | --- |
| WordPress sunucuları | **Fargate** üzerinde ECS | **EC2** instance'ları (C7i / M7i) üzerinde ECS | Fargate Local Zone'larda çalışmıyor. Sunucuları artık kendimiz güncelleyip değiştiriyoruz. |
| Veritabanı | **RDS** MariaDB | Şifreli EBS diskli bir **EC2** instance'ında MariaDB | RDS orada sunulmuyor. Yedek, güncelleme ve izleme bizim işimiz oluyor. |
| Veritabanı yedekleri | RDS yedekleri + AWS Backup | Zone'un kendisinde saklanan gecelik **EBS snapshot'ları**, son 7'si tutulur | Yedek kopyası da İstanbul'da kalmalı. Normal bir snapshot Frankfurt'ta saklanırdı. |
| Ürün görselleri | Frankfurt'ta S3 bucket | Hâlâ Frankfurt'taki S3 bucket (şimdilik) | Zone'daki S3 farklı türde bir bucket ("directory bucket"). Medya eklentisinin ve CloudFront'un bununla çalıştığını henüz doğrulamadık. Ürün fotoğrafları kişisel veri değil. |
| Paylaşılan dosyalar (EFS) | Kullanılmıyor | Kullanılmıyor | Kod imajda, görseller S3'te. İki kurulum aynı görünsün diye EFS'i önce Frankfurt'ta kaldırdık. |
| Cache | ElastiCache (opsiyonel, iki kurulum aynı olsun diye varsayılan kapalı) | Cache yok (şimdilik) | ElastiCache orada sunulmuyor ve cache müşteri verisi tutuyor. Mağaza onsuz da çalışıyor, biraz daha yavaş. |
| Load balancer | 2 AZ'ye yayılan ALB | Zone'un subnet'lerinde ayrı bir ALB | Bir ALB normal AZ subnet'leriyle Local Zone subnet'lerini karıştıramaz. |
| Güvenlik duvarı (WAF) | CloudFront'ta | Hâlâ CloudFront'ta | Local Zone'daki bir ALB'ye WAF bağlanamıyor. Bizimki zaten CloudFront'taydı. |

### Neyden vazgeçiyoruz

- **İki-üç yerine tek konum.** Local Zone tek bir tesis. O giderse mağaza da
  gider. Veritabanı tek instance. Bunu açıkça söylüyoruz; felaket kurtarma
  seçenekleri ayrı bir karar olarak yazıldı.
- **Daha fazla iş.** Yönetilen veritabanı yok, Fargate yok. Sunucuların
  güncellenmesi, veritabanının test ettiğimiz yedeklere ihtiyacı var.
- **Her sayfa hızlanmıyor.** CloudFront önbelleğe alınmış sayfaları zaten
  İstanbul'dan sunuyor. Kazanç önbelleğe alınamayan sayfalarda: sepet, ödeme,
  "hesabım" ve wp-admin.

Kazandığımız: veritabanı, yedekleri ve müşteri verisini işleyen sunucular
Türkiye'de ve bunu gösterebiliyoruz.

### Hâlâ Frankfurt'ta olanlar

| Ne | Kişisel veri? | Plan |
| --- | --- | --- |
| Loglar (CloudWatch Logs) | Evet: ziyaretçi IP adresleri | Residency Guard bulur, sonra düzeltilir (zone'da tut ya da IP'leri maskele) |
| NAT gateway | Üzerinden geçiyor: zone'un internete veya AWS API'lerine gönderdiği her şey | İstanbul NAT gateway destekliyorsa zone'a taşı (`nat_in_local_zone = true`) |
| Ürün görselleri (S3) | Hayır | Eklenti çalıştığında zone'daki bir bucket'a taşı |
| Container registry, secret'lar, Terraform state | Hayır | Frankfurt'ta kalır |

### "Veri gerçekten Türkiye'de mi?"

Sunucuları taşımak yetmez. Veri daha az belirgin yollardan dışarı sızar:
Frankfurt'taki CloudWatch'a giden loglar, geride unutulan eski veritabanı
snapshot'ları, dış servisleri çağıran eklentiler (Gravatar, Google Fonts,
Akismet).

Bu yüzden ilk Local Zone sürümü bilerek basit, naif yoldan yapıldı. Ardından
bir denetim aracı, **Residency Guard**, `data-residency=tr` etiketli her kaynağı
listeler ve gerçekte nerede olduğunu raporlar. Bulduklarını düzeltip tekrar
çalıştırıyoruz. Bu repodaki her veri kaynağı bu etiketleri zaten taşıyor; bu
yüzden Frankfurt kurulumu ilk raporda "her şey Türkiye dışında" olarak görünüyor.

> Bu hukuki tavsiye değildir ve KVKK uyumluluğu iddia etmez. İddia daha dar:
> kişisel veri tutan kaynaklar Türkiye'de ve bunu otomatik bir kontrol kanıtlıyor.

## Proje durumu

| Adım | Ne | Durum |
| --- | --- | --- |
| 1 | Terraform'da Frankfurt kurulumu (`envs/frankfurt-baseline`) | Kod hazır, henüz ölçülmedi |
| 2 | Sahte verili demo mağaza (wordpress-shop-demo) | Tamam |
| 3 | "Hibrit" dönem: uygulama Frankfurt'ta, veritabanı VPN üzerinden şirket içinde | Planlandı |
| 4 | İstanbul Local Zone'a geçiş (`envs/istanbul-lz`) | İlk sürüm yazıldı, henüz uygulanmadı |
| 5–6 | Residency Guard: denetle, düzelt, tekrar denetle | İlk rapor tamam (02.11.2026: 12 ❌, 4 ⚠️, 14 ✅); düzeltmeler ve ikinci tur bekliyor |
| 7 | Türkiye dışındaki bir veritabanını engelleyen CI kontrolleri | Planlandı |
| 8 | Her adım için hız, maliyet ve emek karşılaştırması | Planlandı |

1. ve 4. adımlar yalnızca `terraform validate` ile kontrol edildi. İkisi de
henüz bir AWS hesabına uygulanmadı.

## Repo yapısı

| Yol | Ne |
| --- | --- |
| `bootstrap/` | Hesap başına bir kez çalıştırılır: Terraform state için S3 bucket ve aylık AWS Budgets alarmı. Yerel state. |
| `envs/frankfurt-baseline/` | Faz 1 baseline: Frankfurt, Fargate, RDS. Durumsuz task'lar (EFS yok, medya S3'te). |
| `envs/istanbul-lz/` | Faz 4: İstanbul Local Zone, EC2 üzerinde ECS, EC2 üzerinde MariaDB. |
| `main/` | Frankfurt kurulumunun kök modülü. |
| `lz/` | Local Zone kurulumunun kök modülü. |
| `docs/adr/` | Karar kayıtları (neden Fargate yerine EC2, neden EC2 üzerinde MariaDB). |
| `modules/` | Aşağıdaki yapı taşları. |
| `../residency-guard/` | Ayrı repo ([egeeuzun/residency-guard](https://github.com/egeeuzun/residency-guard)), bu reponun yanına klonlanır: `terraform output residency_guard` çıktısını okuyan salt okunur denetim aracı (Python, boto3) ve raporları. Bkz. README'si. |
| `docs/00-envanter.md` | Bu reponun ve imajın kurduğu her şeyin dökümü. |
| `docs/calistirma-kilavuzu.md` | Kurulum, kontrol ve kaldırma için adım adım kılavuz ([English](docs/running-guide.md)). |

## Modüller

| Modül | Amaç |
| --- | --- |
| `network` | `az_count` AZ'ye yayılan public / app / data subnet'li VPC, AZ başına NAT gateway |
| `network-lz` | Local Zone'da public / app / data subnet'li VPC, NAT parent AZ'de veya zone'da |
| `security` | Her katman için security group'lar |
| `alb` | Application Load Balancer, target group, sağlık kontrolleri |
| `ecs` | Fargate'te veya bir EC2 capacity provider'da ECS servisi, task definition, autoscaling, ECS Exec |
| `ecs-ec2-capacity` | ECS instance'larının Auto Scaling grubu ve capacity provider'ı (Local Zone'lar için) |
| `ecr` | WordPress imajı için container registry |
| `rds` | Opsiyonel read replica ve Multi-AZ standby'lı MariaDB |
| `db-ec2-mariadb` | Tek EC2 instance'ında MariaDB, veri kendi EBS diskinde, DLM ile yerel snapshot'lar |
| `elasticache` | Object cache |
| `efs` | Task'lar arasında opsiyonel paylaşılan `wp-content/uploads` (ve `plugins`/`themes`) |
| `s3` | Versiyonlama ve lifecycle kurallı statik ve medya bucket'ı |
| `cdn` | CloudFront dağıtımı, OAC ile S3 origin, WAF |
| `backup` | AWS Backup planı ve vault |
| `vpn` | Özel subnet'lere yönetici erişimi için Pritunl VPN sunucusu |
| `cicd` | İmaj build ve ECS deploy için CodePipeline ve CodeBuild |
| `residency-audit` | Residency Guard için salt okunur rol, denetim bucket'ı, Athena tabloları; denetim penceresinde VPC Flow Logs ve DNS sorgu logları |

## Kullanım

Bu kısa sürüm. Ön koşullar, imaj build'i, deploy sonrası kontroller, kaldırma
ve sorun giderme için [çalıştırma kılavuzuna](docs/calistirma-kilavuzu.md) bakın.

**1. Bootstrap (hesap başına bir kez)**

```bash
cd bootstrap
cp terraform.tfvars.example terraform.tfvars   # budget_emails'i girin
terraform init && terraform apply
terraform output -raw backend_hcl > ../envs/frankfurt-baseline/backend.hcl
terraform output -raw backend_hcl > ../envs/istanbul-lz/backend.hcl
```

AWS bütçe alarmı için bir onay e-postası gönderir; onaylamadan hiçbir alarm
gelmez. State bucket'ında `prevent_destroy` var.

**2. Bir ortam**

```bash
cd envs/frankfurt-baseline
cp terraform.tfvars.example terraform.tfvars   # admin IP'leri, image_tag
terraform init -backend-config=backend.hcl
terraform apply
```

State, S3'ün kendi kilit dosyasıyla (`use_lockfile`) kilitlenir; DynamoDB
tablosu yok. Her kaynak `project=lz-woo`, `phase`, `environment` ve
`managed-by` varsayılan etiketlerini alır.

**2b. İstanbul Local Zone ortamı**

Aynı adımlar `envs/istanbul-lz` içinde (kendi `backend.hcl` ve
`terraform.tfvars` dosyasıyla). Terraform hesabı Local Zone'a sizin yerinize
kaydeder (opt-in). Aynı hesapta baseline'ın yanında çalışır: kaynak adları,
state ve VPC aralıkları farklı.

`apply`'dan sonra sunucuların hazır olması birkaç dakika sürer: ECS task'lar
için EC2 instance'ları ekler, veritabanı instance'ı ilk açılışta MariaDB'yi
kurar. Veritabanı sunucusuna bağlanmak için:

```bash
aws ssm start-session --target $(terraform output -raw db_instance_id)
```

**3. Mağazayı doldurun**

İmajı CI/CD hattıyla push edin (ya da `container_image` verin).

Her ortamın, ECS servisiyle aynı `apply`'da oluşturulan kendi ECR reposu var.
İmajı elle push ediyorsanız önce repoyu oluşturun, push edin, sonra geri
kalanını apply edin. İmaj `linux/amd64` olmalı (instance'lar C7i/M7i):

```bash
terraform apply -target=module.lz.module.ecr     # frankfurt-baseline'da module.main.module.ecr
docker push <ecr_repository_url>:<tag>
terraform apply -var image_tag=<tag>
```

Ölçüm turlarında `image_tag`'i commit SHA'sı yapın: `latest` değişir ve
sonraki `apply` servisi `image_tag` neyi gösteriyorsa ona geri alır.

İki ortam da mağazayı kendiliğinden doldurur (`enable_auto_seed`, varsayılan
açık). Bir task başladığında imaj, kurulu değilse WordPress'i Türkçe kurar,
sonra bu veritabanı seed kitinin bu sürümünü görmediyse kiti çalıştırır. İşi
yalnızca bir task yapar; konteyner logunda takip edin (`[auto-seed]` ile
başlayan satırlar). Yönetici kullanıcı `admin`; parolası `admin123` **değil**
(o yalnızca uygulama reposunun yerel varsayılanı). Terraform parolayı üretir ve
SSM'de tutar:

```bash
aws ssm get-parameter --with-decryption --query Parameter.Value --output text \
  --name $(terraform output -raw admin_password_ssm_name)
```

Kendiniz seçmek için `terraform.tfvars` içinde `wp_admin_password` verin. Her
task başlangıcında imaj yönetici parolasını SSM'deki değere eşitler; böylece
daha önce başka bir parolayla kurulmuş bir WordPress'i de düzeltir. wp-admin'de
ya da `wp user update` ile değiştirilen bir parola sonraki task başlangıcında
sıfırlanır. Değeri değiştirmek task definition'ı değiştirir, yani
`terraform apply` task'ları yeniler. Seed sonraki deploy'da yine bir kez
çalışır. Seed'i elle çalıştırmak için ECS Exec kullanın:

```bash
aws ecs execute-command --cluster <ecs_cluster_name> --task <TASK_ID> --container wordpress \
  --interactive --command "su -s /bin/sh www-data -c 'wp eval-file /usr/src/shop-seed/seed.php'"
```

Bütün girdi değişkenleri `main/variables.tf` içinde belgelenmiştir.

### Eski `env/` dizininden geçiş

`env/test_prod.tf` artık `envs/frankfurt-baseline`. Yerel state'i otomatik
taşınmaz. Mevcut kaynakları korumak için `terraform.tfvars` içinde
`project = "wordpress HA"` ve `env = "Test"` verin (kaynak adları bunlardan
gelir), sonra:

```bash
terraform init -backend-config=backend.hcl
terraform state push ../../env/terraform.tfstate
terraform plan
```

Baseline EFS'i kapatır. Mevcut bir kurulumda bu, dosya sistemini ve içindeki
her şeyi siler; yüklemeler henüz S3'te değilse önce
`envs/frankfurt-baseline/main.tf` içinde `enable_efs = true` yapın.

## Notlar

- **WordPress salt'ları** `random_password` ile üretilir, SSM Parameter
  Store'da `/<name>/wp-salts/` altında saklanır ve task'a `WORDPRESS_*`
  secret'ları olarak verilir. Bunlar olmadan imaj sabit, herkesçe bilinen
  varsayılanlara düşer. Yeniden üretmek herkesin oturumunu kapatır.
- **Durumsuz mod (`enable_efs = false`)** `offload_uploads_to_s3 = true` ve
  `enable_plugin_installs = false` gerektirir; aksi halde plan durur. Kod
  imajdan, medya S3'ten gelir ve bir task hiçbir şey kaybetmeden
  değiştirilebilir. Local Zone'larda EFS olmadığından bu, baseline'ı
  karşılaştırılabilir tutar.
- **Task definition değişiklikleri servise ulaşır.** ECS servisi Terraform'daki
  task definition'ı izler. CodePipeline deploy'u servisin mevcut revizyonunu
  kopyalayıp yalnızca imajı değiştirir; sonraki `terraform apply` servisi
  `:latest` altındaki aynı imaja geri alır.
- **Veri etiketleri.** Mağaza verisi tutan kaynaklar
  `data-residency=<data_residency>` (varsayılan `tr`) ve `data-class` ile
  etiketlenir (veritabanı ve replica'sı, snapshot'lar ve yedekler, EFS,
  ElastiCache ve ECS log grupları için `personal`; medya bucket'ı için
  `non-personal`). Projenin ilerleyen adımlarındaki konum kontrolleri bu
  etiketleri kullanır.
- ALB sağlık kontrolü imajın WordPress'i yüklemeyen `/health.php` dosyasını
  kullanır (`health_check_path`).
- `MEMCACHED_HOST` bütün ElastiCache node'larını listeler; imajın istemcisi
  auto-discovery yapmaz.
- `enable_vpn = true` iken `vpn_admin_cidrs` zorunludur; `0.0.0.0/0` reddedilir.
- Veritabanı parolası `random_password` ile üretilir ve SSM Parameter Store'da
  saklanır. Parola (ve salt'lar) state'e de düz metin yazılır; bootstrap state
  bucket'ı şifreli ve dışarıya kapalıdır.
- `static_bucket_force_destroy` varsayılan olarak `true`; production'da `false`
  yapın.
- `offload_uploads_to_s3`'ü yalnızca konteyner imajında medyayı S3'e yazan bir
  eklenti varsa açın.

## Gereksinimler

- `envs/` ve `bootstrap/` kökleri için Terraform >= 1.11 (`main/` tek başına >= 1.5 ile çalışır)
- AWS provider >= 5.79, < 6.0
- Yapılandırılmış AWS kimlik bilgileri
