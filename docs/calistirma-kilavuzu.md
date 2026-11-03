# Çalıştırma kılavuzu

[English](running-guide.md) · **Türkçe** · [README](../README.tr.md)

Bu kılavuz, boş bir AWS hesabından çalışan bir *Yerel Market* mağazasına,
sonra da tekrar sıfır maliyete giden yolu adım adım anlatır. İki ortamdan
birini (ya da ikisini birden, aynı hesapta) kurabilirsiniz:

| Ortam | Dizin | Nerede çalışır |
| --- | --- | --- |
| Frankfurt baseline | `envs/frankfurt-baseline` | `eu-central-1`, 2 AZ, ECS Fargate + RDS |
| İstanbul Local Zone | `envs/istanbul-lz` | `eu-central-1-ist-1a`, EC2 üzerinde ECS + EC2 üzerinde MariaDB |

> ⚠️ **Maliyet uyarısı.** Bu kurulumlar NAT gateway, ALB, CloudFront, WAF ve
> `m7i.large` sınıfı sunucular açar; saat başı ücretlendirilir. Her deneme ya
> da ölçüm turundan sonra [ortamı kaldırın](#11-kaldırma). Bootstrap'taki bütçe
> alarmı unutulanı yakalamak içindir, onun yerine geçmez.

## Akış özeti

```
1. Araçları kur      ─►  2. AWS'ye bağlan   ─►  3. Repoları klonla
4. Bootstrap (bir kez): state bucket + bütçe alarmı
5. Ortam ayarları (backend.hcl, terraform.tfvars) ─► terraform init
6. ECR reposunu oluştur ─► 7. İmajı build edip push et
8. terraform apply ─► 9. Kontrol et (site, loglar, admin parolası)
10. (Opsiyonel) Residency Guard denetimi
11. terraform destroy + snapshot temizliği
```

## 1. Ön koşullar

| Araç | Sürüm | Ne için |
| --- | --- | --- |
| [Terraform](https://developer.hashicorp.com/terraform/install) | **>= 1.11** | `envs/` ve `bootstrap/` kökleri (S3 native state kilidi 1.11 ister) |
| [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) | güncel | Kimlik doğrulama, ECR girişi, SSM, loglar |
| [Session Manager eklentisi](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) | güncel | `aws ssm start-session` ve `aws ecs execute-command` |
| Docker + buildx | güncel | WordPress imajını `linux/amd64` olarak build etmek |
| git | — | Repoları klonlamak |

Ayrıca:

- Bir **AWS hesabı** ve geniş yetkili bir IAM kullanıcısı/rolü. Kurulum VPC,
  IAM rolleri, ECS, RDS/EC2, CloudFront, WAF, SSM, S3, DLM, Budgets gibi pek
  çok servise dokunur; deneme hesabında `AdministratorAccess` en sorunsuz yol.
- Bütçe alarmlarının gideceği bir **e-posta adresi**.
- Apple Silicon (ARM) bir Mac kullanıyorsanız imajı mutlaka
  `--platform linux/amd64` ile build edin (bkz. [7. adım](#7-imaji-build-edip-push-etme)).

Sürümleri kontrol edin:

```bash
terraform version
aws --version
session-manager-plugin --version
docker buildx version
```

## 2. AWS'ye bağlanma

Kimlik bilgilerinizi bir profil olarak ayarlayın (SSO kullanıyorsanız
`aws configure sso`):

```bash
aws configure --profile lz-woo
```

```bash
export AWS_PROFILE=lz-woo
export AWS_REGION=eu-central-1
```

Doğru hesaba bağlı olduğunuzu doğrulayın:

```bash
aws sts get-caller-identity
```

Bu kılavuzdaki bütün komutlar aynı terminalde, bu iki değişken ayarlıyken
çalıştırılmalıdır.

## 3. Repoları klonlama

Üç repo yan yana durur. Residency Guard yalnızca denetim için gerekir.

```bash
mkdir lz-woo && cd lz-woo
git clone https://github.com/egeeuzun/woocommerce-istanbul-local-zone.git
git clone https://github.com/egeeuzun/wordpress-shop-demo.git
git clone https://github.com/egeeuzun/residency-guard.git
```

Sonuç:

```
lz-woo/
├── woocommerce-istanbul-local-zone/   ← bu repo (Terraform)
├── wordpress-shop-demo/               ← WordPress + WooCommerce imajı ve seed kiti
└── residency-guard/                   ← veri konumu denetim aracı
```

Kılavuzun geri kalanında `<repo>` bu reponun kök dizinidir.

## 4. Bootstrap (hesap başına bir kez)

Bootstrap, ortamların Terraform state'ini tutacak şifreli S3 bucket'ını ve
aylık bütçe alarmını kurar. Kendi state'i yerelde (`bootstrap/terraform.tfstate`)
durur; bu dosyayı silmeyin.

```bash
cd <repo>/bootstrap
cp terraform.tfvars.example terraform.tfvars
```

`terraform.tfvars` içinde `budget_emails` alanına kendi adresinizi yazın.
İsterseniz `budget_thresholds_usd` ile eşikleri değiştirin (varsayılan
`[30, 60, 100]` USD). Sonra:

```bash
terraform init
terraform apply
```

Her iki ortam için `backend.hcl` dosyasını üretin:

```bash
terraform output -raw backend_hcl > ../envs/frankfurt-baseline/backend.hcl
terraform output -raw backend_hcl > ../envs/istanbul-lz/backend.hcl
```

✅ **Kontrol:** AWS her adrese "AWS Notification – Subscription Confirmation"
benzeri bir e-posta gönderir. Onaylamadan bütçe alarmı gelmez.

> State bucket'ında `prevent_destroy` var; `terraform destroy` ile silinmez.
> Bu bilerek böyle: state'i kaybetmek, kurduğunuz kaynakları Terraform'un
> göremez hale gelmesi demektir.

## 5. Ortamı ayarlama

Kurmak istediğiniz ortamın dizinine geçin. Örnekler İstanbul için; Frankfurt
için `envs/frankfurt-baseline` kullanın, adımlar aynı.

```bash
cd <repo>/envs/istanbul-lz
cp terraform.tfvars.example terraform.tfvars
```

`terraform.tfvars` içindeki önemli alanlar:

| Değişken | Ne yapar | Öneri |
| --- | --- | --- |
| `admin_extra_allowed_cidrs` | WAF, `wp-admin` ve `wp-login.php`'yi yalnızca bu IP'lere açar. Boş bırakılırsa wp-admin kısıtlamasız kalır. | Kendi IP'niz `/32` |
| `wp_admin_password` | WordPress `admin` parolası. Yorumda kalırsa Terraform rastgele üretip SSM'ye yazar. | Yorumda bırakın |
| `image_tag` | ECR'dan çekilecek imaj tag'i. Varsayılan `latest`. | Commit SHA'sı |
| `enable_cicd` ve ilgili alanlar | İmajı CodePipeline ile build edip deploy eder. | [7B](#7b-cicd-hattı-ile-opsiyonel) |
| `nat_in_local_zone` | *(Yalnızca İstanbul)* NAT gateway'i Frankfurt yerine Local Zone'a koyar. | İstanbul'da NAT desteği doğrulanırsa `true` |
| `ecs_instance_type`, `db_instance_type` | *(Yalnızca İstanbul)* Varsayılan `m7i.large`. | Zone'da yoksa değiştirin ([sorun giderme](#12-sorun-giderme)) |
| `enable_vpn`, `vpn_admin_cidrs` | *(Yalnızca Frankfurt)* Pritunl yönetim VPN'i. | Gerekmedikçe kapalı |

Genel IP adresinizi öğrenmek için:

```bash
curl -s https://checkip.amazonaws.com
```

Terraform'u başlatın:

```bash
terraform init -backend-config=backend.hcl
```

Bütün değişkenler ve açıklamaları: `envs/<ortam>/variables.tf`,
`main/variables.tf` (Frankfurt) ve `lz/variables.tf` (İstanbul).

## 6. ECR reposunu oluşturma

İmajı push etmeden önce ortamın container registry'si (ECR) var olmalı. Önce
yalnızca onu oluşturun:

```bash
# İstanbul:
terraform apply -target=module.lz.module.ecr
```

```bash
# Frankfurt:
terraform apply -target=module.main.module.ecr
```

Terraform, `-target` kullanıldığı için bir uyarı verir; bu adımda beklenen bir
durum.

<a id="7-imaji-build-edip-push-etme"></a>

## 7. İmajı build edip push etme

İki yol var: elle push (7A, ilk deneme için önerilir) ya da CI/CD hattı (7B).

### 7A. Elle push

ECR adresini alın ve Docker'ı ECR'a bağlayın (ortam dizinindeyken):

```bash
REPO_URL=$(terraform output -raw ecr_repository_url)
```

```bash
aws ecr get-login-password | docker login --username AWS --password-stdin "${REPO_URL%%/*}"
```

İmajı `wordpress-shop-demo` reposundan build edip push edin. Tag olarak commit
SHA'sını kullanın:

```bash
cd ../../../wordpress-shop-demo
TAG=$(git rev-parse --short HEAD)
docker buildx build --platform linux/amd64 -t "$REPO_URL:$TAG" --push .
cd -
```

> İmaj **mutlaka `linux/amd64`** olmalı: sunucular Intel tabanlı (C7i/M7i).
> ARM imajı ile task'lar `exec format error` vererek kapanır.

### 7B. CI/CD hattı ile (opsiyonel)

1. AWS konsolunda **Developer Tools → Settings → Connections** altında GitHub
   için bir bağlantı oluşturun ve onaylayın (durumu *Available* olmalı).
2. `terraform.tfvars` içinde açın:

   ```hcl
   enable_cicd             = true
   codestar_connection_arn = "arn:aws:codestar-connections:eu-central-1:<HESAP>:connection/<ID>"
   repository_id           = "<kullanici>/wordpress-shop-demo"
   branch                  = "main"
   ```

3. [8. adımdaki](#8-ortamı-kurma) `apply`'dan sonra hat ilk build'i başlatır ve
   seçilen branch'e her push'ta yeniden build edip deploy eder.

> Hat, servisin mevcut task definition'ını kopyalayıp yalnızca imajı değiştirir.
> Sonraki `terraform apply` servisi `image_tag`'in gösterdiği imaja geri alır.
> Ölçüm turlarında `image_tag`'i sabit bir SHA'ya ayarlayın.

## 8. Ortamı kurma

```bash
terraform apply -var image_tag=$TAG
```

(`image_tag`'i `terraform.tfvars`'a yazdıysanız `-var` gerekmez.)

Plan'ı okuyup `yes` yazın. İlk kurulum yaklaşık 15–30 dakika sürer; en uzun
kısım CloudFront dağıtımıdır.

`apply` bittikten sonra da birkaç dakika bekleyin:

- **İstanbul:** ECS, task'lar için EC2 instance'ları açar; veritabanı
  instance'ı ilk açılışta MariaDB'yi kurar.
- **İki ortamda da:** ilk task WordPress'i Türkçe kurar ve seed kitiyle
  mağazayı doldurur (`enable_auto_seed`, varsayılan açık).

> İstanbul ortamı hesabınızı Local Zone'a sizin yerinize kaydeder
> (`aws_ec2_availability_zone_group`). Bu kayıt AWS API'siyle geri alınamaz;
> `destroy` yalnızca state'ten çıkarır. Ücreti yoktur.

## 9. Kontrol etme

### Site

```bash
terraform output -raw site_url
```

Adresi tarayıcıda açın; *Yerel Market* ana sayfası gelmeli. Hemen gelmezse
(502/503) seed bitene kadar birkaç dakika bekleyin.

Task'ların çalıştığını görmek için:

```bash
CLUSTER=$(terraform output -raw ecs_cluster_name)
aws ecs list-tasks --cluster "$CLUSTER" --desired-status RUNNING
```

### Admin girişi

Kullanıcı adı `admin`. Parola (`admin123` **değil**):

```bash
aws ssm get-parameter --with-decryption --query Parameter.Value --output text \
  --name $(terraform output -raw admin_password_ssm_name)
```

Giriş adresi: `<site_url>/wp-admin`. 403 alırsanız IP'niz
`admin_extra_allowed_cidrs` içinde değildir.

### Konteyner logları ve seed

Seed satırları `[auto-seed]` ile başlar.

**Frankfurt** — loglar CloudWatch Logs'ta (`/ecs/<project>-<env>-wordpress`,
varsayılan `lz-woo-baseline`):

```bash
aws logs tail /ecs/lz-woo-baseline-wordpress --follow | grep auto-seed
```

**İstanbul** — loglar veri Türkiye dışına çıkmasın diye CloudWatch'a değil,
ECS instance'ının diskine yazılır (`json-file`). Önce instance'ı bulun:

```bash
aws ecs describe-container-instances --cluster "$CLUSTER" \
  --container-instances $(aws ecs list-container-instances --cluster "$CLUSTER" --query 'containerInstanceArns' --output text) \
  --query 'containerInstances[].ec2InstanceId' --output text
```

Sonra bağlanıp konteyner logunu okuyun:

```bash
aws ssm start-session --target <ec2-instance-id>
```

```bash
sudo docker ps --format '{{.ID}} {{.Names}}' | grep wordpress
sudo docker logs -f <container-id> 2>&1 | grep auto-seed
```

### Konteynere girme ve seed'i elle çalıştırma (ECS Exec)

```bash
TASK=$(aws ecs list-tasks --cluster "$CLUSTER" --query 'taskArns[0]' --output text)
```

```bash
aws ecs execute-command --cluster "$CLUSTER" --task "$TASK" --container wordpress \
  --interactive --command "su -s /bin/sh www-data -c 'wp eval-file /usr/src/shop-seed/seed.php'"
```

### Veritabanı sunucusuna bağlanma (yalnızca İstanbul)

```bash
aws ssm start-session --target $(terraform output -raw db_instance_id)
```

Faydalı diğer çıktılar: `terraform output` (hepsi), `local_zone`,
`nat_location`, `db_endpoint`, `alb_dns_name`.

## 10. Residency Guard denetimi (opsiyonel, İstanbul)

Residency Guard, `data-residency=tr` etiketli kaynakların gerçekte nerede
durduğunu raporlar. Ayrıntılar ve aracın kendisini çalıştırma:
[residency-guard README](https://github.com/egeeuzun/residency-guard).

1. **Denetim penceresini açın** (Flow Logs ve DNS sorgu logları; IP adresi
   içerir). `terraform.tfvars`:

   ```hcl
   residency_capture_enabled    = true
   residency_log_retention_days = 3
   # İlk DB snapshot'ı için geceyi beklememek: apply'dan ~1 saat sonrası (UTC).
   # Türkiye saati UTC+3: 15:30 TR için "12:30".
   db_snapshot_time_utc = "12:30"
   ```

   ```bash
   terraform apply
   ```

2. Sitede biraz gezinin, sepete ürün ekleyin, sipariş verin; trafik oluşsun.
3. Ayarları Residency Guard'a verin (ortam dizinindeyken):

   ```bash
   terraform output -json residency_guard > ../../../residency-guard/guard.json
   ```

4. Residency Guard'ı kendi README'sine göre çalıştırın ve raporu inceleyin.
5. **Pencereyi kapatın:** `residency_capture_enabled = false` yapın,
   `db_snapshot_time_utc` satırını silin ve `terraform apply` çalıştırın.

## 11. Kaldırma

Her deneme veya ölçüm turundan sonra ortamı kaldırın:

```bash
cd <repo>/envs/istanbul-lz      # ya da envs/frankfurt-baseline
terraform destroy
```

`destroy` bazı şeyleri bilerek geride bırakır:

| Kalan | Neden | Ne yapmalı |
| --- | --- | --- |
| **DLM'in aldığı EBS snapshot'ları** (İstanbul) | Terraform onları oluşturmadı, DLM oluşturdu | Aşağıdaki komutla silin |
| Local Zone kaydı (opt-in) | API ile kapatılamıyor | Ücretsiz, dokunmayın |
| Bootstrap state bucket'ı ve bütçe alarmı | `prevent_destroy`; diğer ortamlar kullanıyor | Projeyi tamamen bitirene kadar tutun |

Kalan veritabanı snapshot'larını bulup silin (kişisel veri içerirler):

```bash
aws ec2 describe-snapshots --owner-ids self \
  --filters Name=tag-key,Values=lz-woo-snapshot \
  --query 'Snapshots[].[SnapshotId,StartTime,Tags[?Key==`lz-woo-snapshot`]|[0].Value]' --output table
```

```bash
aws ec2 delete-snapshot --snapshot-id <snap-id>
```

Projeyi tamamen bitirdiyseniz bootstrap'ı da kaldırabilirsiniz: önce
`bootstrap/main.tf` içindeki `prevent_destroy = true` satırını kaldırın, state
bucket'ını boşaltın (versiyonlu olduğu için eski versiyonlar dahil), sonra
`bootstrap` dizininde `terraform destroy` çalıştırın.

## 12. Sorun giderme

| Belirti | Olası neden | Çözüm |
| --- | --- | --- |
| `terraform init`: `Unsupported Terraform Core version` | Terraform 1.11'den eski | Terraform'u güncelleyin |
| `init`: bucket bulunamadı / `backend.hcl` yok | Bootstrap çıktısı yazılmadı | [4. adımdaki](#4-bootstrap-hesap-başına-bir-kez) `terraform output -raw backend_hcl` komutunu çalıştırın |
| `Error acquiring the state lock` | Yarıda kalmış bir `apply` kilit dosyası bıraktı | Başka bir `apply` çalışmadığından emin olun, sonra `terraform force-unlock <LOCK_ID>` |
| Task'lar sürekli `STOPPED`, sebep `CannotPullContainerError` | İmaj ECR'da yok ya da `image_tag` yanlış | [7. adımı](#7-imaji-build-edip-push-etme) tekrarlayın, `image_tag`'i kontrol edin |
| Task log'unda `exec format error` | İmaj ARM için build edilmiş | `--platform linux/amd64` ile yeniden build edin |
| İstanbul'da instance açılmıyor (`Unsupported` / `InsufficientInstanceCapacity`) | Instance tipi zone'da yok ya da kapasite dolu | Aşağıdaki komutla mevcut tipleri görün, `ecs_instance_type`/`db_instance_type`'ı değiştirin |
| Site 502/503 veriyor | Task'lar henüz sağlıklı değil ya da seed sürüyor | Birkaç dakika bekleyin, logları kontrol edin |
| `wp-admin` 403 veriyor | IP'niz WAF listesinde değil | `admin_extra_allowed_cidrs`'e ekleyip `apply` |
| Admin parolası kabul edilmiyor | wp-admin'de değiştirilen parola task yeniden başlayınca SSM'deki değere döner | SSM'deki değeri kullanın ya da `wp_admin_password` verin |
| `aws ssm start-session` / `execute-command`: `SessionManagerPlugin is not found` | Eklenti kurulu değil | [Session Manager eklentisini](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) kurun |
| `main.tf`'te ayar değiştirdikten sonra plan EFS hatasıyla duruyor | `enable_efs = false` için `offload_uploads_to_s3 = true` ve `enable_plugin_installs = false` gerekir | README'deki *Notlar* bölümüne bakın |
| Bütçe alarmı gelmiyor | Abonelik e-postası onaylanmadı | Gelen kutusunda/spam'de AWS e-postasını onaylayın |

İstanbul Local Zone'daki instance tipleri:

```bash
aws ec2 describe-instance-type-offerings --location-type availability-zone \
  --filters Name=location,Values=eu-central-1-ist-1a \
  --query 'InstanceTypeOfferings[].InstanceType' --output text
```

## Komut özeti

```bash
# Bir kez
cd <repo>/bootstrap && cp terraform.tfvars.example terraform.tfvars   # e-postayı girin
terraform init && terraform apply
terraform output -raw backend_hcl > ../envs/istanbul-lz/backend.hcl

# Ortam
cd ../envs/istanbul-lz && cp terraform.tfvars.example terraform.tfvars   # IP'nizi girin
terraform init -backend-config=backend.hcl
terraform apply -target=module.lz.module.ecr
REPO_URL=$(terraform output -raw ecr_repository_url)
aws ecr get-login-password | docker login --username AWS --password-stdin "${REPO_URL%%/*}"
(cd ../../../wordpress-shop-demo && docker buildx build --platform linux/amd64 -t "$REPO_URL:$(git rev-parse --short HEAD)" --push .)
terraform apply -var image_tag=$(git -C ../../../wordpress-shop-demo rev-parse --short HEAD)
terraform output -raw site_url

# Bitince
terraform destroy
```
