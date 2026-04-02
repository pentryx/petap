#!/usr/bin/env bash
# =============================================================================
#  Pardus Remaster Script
#  Kurulu Pardus sistemini bootable ISO'ya dönüştürür.
#  Kullanım: sudo bash pardus-remaster.sh
# =============================================================================

set -euo pipefail

# --- Renkler ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- Yardımcı fonksiyonlar ---
info()    { echo -e "${CYAN}[BİLGİ]${NC} $*"; }
success() { echo -e "${GREEN}[TAMAM]${NC} $*"; }
warn()    { echo -e "${YELLOW}[UYARI]${NC} $*"; }
error()   { echo -e "${RED}[HATA]${NC} $*"; exit 1; }
step()    { echo -e "\n${BOLD}${GREEN}━━━ $* ${NC}"; }

banner() {
cat << 'EOF'
╔═══════════════════════════════════════════════════════╗
║          PARDUS REMASTERs ARACI v1.0                  ║
║   Kurulu sistemi bootable ISO'ya dönüştürür           ║
╚═══════════════════════════════════════════════════════╝
EOF
}

# =============================================================================
# ROOT KONTROLÜ
# =============================================================================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Bu script root yetkisiyle çalışmalıdır. Tekrar deneyin: sudo bash $0"
    fi
}

# =============================================================================
# BAĞIMLILIK KONTROLÜ
# =============================================================================
check_deps() {
    step "Gerekli araçlar kontrol ediliyor..."
    local missing=()
    for cmd in mksquashfs xorriso rsync wget isoinfo; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "Eksik paketler kuruluyor: ${missing[*]}"
        local pkgs=""
        for cmd in "${missing[@]}"; do
            case "$cmd" in
                mksquashfs) pkgs+=" squashfs-tools" ;;
                xorriso)    pkgs+=" xorriso" ;;
                rsync)      pkgs+=" rsync" ;;
                wget)       pkgs+=" wget" ;;
                isoinfo)    pkgs+=" genisoimage" ;;
            esac
        done
        apt-get update -qq
        apt-get install -y $pkgs
        success "Gerekli paketler kuruldu."
    else
        success "Tüm gerekli araçlar mevcut."
    fi

    # isolinux kontrolü
    if [[ ! -f /usr/lib/ISOLINUX/isohdpfx.bin ]]; then
        apt-get install -y isolinux -qq
    fi
}

# =============================================================================
# PARDUS SÜRÜMÜ OTOMATİK TESPİT
# =============================================================================
detect_pardus() {
    if [[ ! -f /etc/os-release ]]; then
        error "/etc/os-release bulunamadı. Bu bir Pardus sistemi mi?"
    fi

    source /etc/os-release

    if [[ "$ID" != "pardus" ]] && [[ "$ID_LIKE" != *"debian"* ]]; then
        warn "Bu sistem Pardus olarak tanımlanamadı (ID=$ID). Devam etmek ister misiniz?"
        read -rp "Devam et? [e/H]: " ans
        [[ "$ans" != "e" && "$ans" != "E" ]] && error "İptal edildi."
    fi

    PARDUS_VERSION="${VERSION_ID:-23.4}"
    info "Tespit edilen sürüm: Pardus $PARDUS_VERSION"
}

# =============================================================================
# MASAÜSTÜ ORTAMI TESPİT
# =============================================================================
detect_desktop() {
    if command -v gnome-shell &>/dev/null; then
        DESKTOP="GNOME"
    elif command -v xfce4-session &>/dev/null; then
        DESKTOP="XFCE"
    else
        warn "Masaüstü ortamı otomatik tespit edilemedi."
        echo "  1) GNOME"
        echo "  2) XFCE"
        read -rp "Seçiminiz [1/2]: " dsel
        case "$dsel" in
            1) DESKTOP="GNOME" ;;
            2) DESKTOP="XFCE"  ;;
            *) error "Geçersiz seçim." ;;
        esac
    fi
    info "Masaüstü ortamı: $DESKTOP"
}

# =============================================================================
# ÇIKTI DİZİNİ SEÇİMİ
# =============================================================================
select_output_dir() {
    step "Çıktı dizini belirleniyor..."

    DEFAULT_DIR="$HOME/pardus-remaster"
    read -rp "Çalışma dizini (Enter = $DEFAULT_DIR): " WORK_DIR
    WORK_DIR="${WORK_DIR:-$DEFAULT_DIR}"

    # Boş alan kontrolü (en az 12 GB)
    AVAIL_KB=$(df -k "$(dirname "$WORK_DIR")" | awk 'NR==2 {print $4}')
    AVAIL_GB=$(( AVAIL_KB / 1024 / 1024 ))

    if [[ $AVAIL_GB -lt 10 ]]; then
        warn "Seçilen dizinde yalnızca ${AVAIL_GB} GB boş alan var. En az 10 GB önerilir."
        read -rp "Yine de devam et? [e/H]: " ans
        [[ "$ans" != "e" && "$ans" != "E" ]] && error "İptal edildi."
    fi

    ISO_DIR="$WORK_DIR/iso-work"
    SQUASHFS_TMP="$WORK_DIR/squashfs-tmp"
    OUTPUT_ISO="$WORK_DIR/Pardus-${PARDUS_VERSION}-${DESKTOP}-custom.iso"

    mkdir -p "$ISO_DIR" "$SQUASHFS_TMP"
    success "Çalışma dizini: $WORK_DIR"
}

# =============================================================================
# ORİJİNAL ISO İNDİR
# =============================================================================
download_iso() {
    step "Orijinal Pardus ISO'su indiriliyor..."

    ISO_URL="https://indir.pardus.org.tr/ISO/Pardus23/Pardus-${PARDUS_VERSION}-${DESKTOP}-amd64.iso"
    ISO_FILE="$WORK_DIR/Pardus-${PARDUS_VERSION}-${DESKTOP}-amd64.iso"

    if [[ -f "$ISO_FILE" ]]; then
        info "ISO zaten mevcut: $ISO_FILE"
        read -rp "Yeniden indir? [e/H]: " redown
        if [[ "$redown" == "e" || "$redown" == "E" ]]; then
            rm -f "$ISO_FILE"
        fi
    fi

    if [[ ! -f "$ISO_FILE" ]]; then
        info "İndiriliyor: $ISO_URL"
        wget -c --progress=bar:force "$ISO_URL" -O "$ISO_FILE" || \
            error "ISO indirilemedi. İnternet bağlantınızı ve URL'yi kontrol edin."
        success "ISO indirildi."
    fi

    ISO_FILE_PATH="$ISO_FILE"
}

# =============================================================================
# ISO AÇMA
# =============================================================================
extract_iso() {
    step "ISO dosyası açılıyor..."

    MOUNT_POINT="$WORK_DIR/iso-mount"
    mkdir -p "$MOUNT_POINT"

    # Önceki mount varsa temizle
    mountpoint -q "$MOUNT_POINT" && umount "$MOUNT_POINT" 2>/dev/null || true

    mount -o loop,ro "$ISO_FILE_PATH" "$MOUNT_POINT"
    rsync -a --info=progress2 "$MOUNT_POINT/" "$ISO_DIR/"
    umount "$MOUNT_POINT"
    rmdir "$MOUNT_POINT"

    success "ISO içeriği $ISO_DIR dizinine kopyalandı."
}

# =============================================================================
# DIŞARI BIRAKILAN DİZİNLER
# =============================================================================
build_exclude_list() {
    EXCLUDES=(
        /proc
        /sys
        /dev
        /run
        /tmp
        /mnt
        /media
        /lost+found
        /swapfile
        /var/tmp
        /var/cache/apt/archives
    )

    # Çalışma dizinini dışarıda bırak
    EXCLUDES+=("$WORK_DIR")

    # Tarayıcı cache'leri (isteğe bağlı)
    if [[ "$SKIP_CACHE" == "yes" ]]; then
        for homedir in /home/*/; do
            EXCLUDES+=("${homedir}.cache")
            EXCLUDES+=("${homedir}.local/share/Trash")
        done
        EXCLUDES+=(/root/.cache)
    fi
}

ask_cache_exclusion() {
    echo ""
    read -rp "Kullanıcı cache dizinleri (~/.cache) dışarıda bırakılsın mı? (ISO boyutunu küçültür) [E/h]: " cans
    if [[ "$cans" != "h" && "$cans" != "H" ]]; then
        SKIP_CACHE="yes"
        info "Cache dizinleri dışarıda bırakılacak."
    else
        SKIP_CACHE="no"
    fi
}

# =============================================================================
# SQUASHFS OLUŞTURMA
# =============================================================================
create_squashfs() {
    step "Mevcut sistem squashfs olarak paketleniyor..."
    info "Bu işlem sistem boyutuna göre 10-45 dakika sürebilir."

    build_exclude_list

    # Exclude argümanlarını oluştur
    EXCL_ARGS=()
    for excl in "${EXCLUDES[@]}"; do
        EXCL_ARGS+=(-e "$excl")
    done

    SQUASHFS_OUT="$ISO_DIR/live/filesystem.squashfs"

    # Önceki squashfs varsa yedekle
    if [[ -f "$SQUASHFS_OUT" ]]; then
        mv "$SQUASHFS_OUT" "${SQUASHFS_OUT}.bak"
        info "Önceki filesystem.squashfs yedeklendi."
    fi

    mksquashfs / "$SQUASHFS_OUT" \
        -comp xz \
        -noappend \
        -no-progress \
        "${EXCL_ARGS[@]}" \
        2>&1 | while IFS= read -r line; do
            echo -ne "\r${CYAN}[SQUASHFS]${NC} $line                    "
        done
    echo ""

    success "filesystem.squashfs oluşturuldu: $(du -sh "$SQUASHFS_OUT" | cut -f1)"
}

# =============================================================================
# BOYUT DOSYASINI GÜNCELLE (Calamares için)
# =============================================================================
update_size_file() {
    step "Calamares için boyut dosyası güncelleniyor..."

    local size_file="$ISO_DIR/live/filesystem.size"
    local total=0

    # Dışarıda bırakılan dizinlerin toplam boyutunu hesapla
    local exclude_size=0
    for excl in "${EXCLUDES[@]}"; do
        if [[ -d "$excl" ]]; then
            s=$(du -sb "$excl" 2>/dev/null | cut -f1 || echo 0)
            exclude_size=$(( exclude_size + s ))
        elif [[ -f "$excl" ]]; then
            s=$(stat -c%s "$excl" 2>/dev/null || echo 0)
            exclude_size=$(( exclude_size + s ))
        fi
    done

    total=$(df --block-size=1 / | awk 'NR==2 {print $3}')
    echo "$total" > "$size_file"
    success "filesystem.size güncellendi: $total byte"
}

# =============================================================================
# MD5 GÜNCELLE
# =============================================================================
update_md5() {
    step "MD5 dosyası güncelleniyor..."
    cd "$ISO_DIR"
    find . -type f -not -name 'md5sum.txt' | sort | xargs md5sum > md5sum.txt
    success "md5sum.txt güncellendi."
    cd - > /dev/null
}

# =============================================================================
# ISO OLUŞTUR
# =============================================================================
build_iso() {
    step "Yeni ISO oluşturuluyor..."

    local efi_img=""
    # EFI imajı yolunu bul
    for candidate in \
        "$ISO_DIR/boot/grub/efi.img" \
        "$ISO_DIR/EFI/boot/efi.img" \
        "$ISO_DIR/efi.img"
    do
        if [[ -f "$candidate" ]]; then
            efi_img="${candidate#$ISO_DIR}"
            break
        fi
    done

    local xorriso_args=(
        -outdev "$OUTPUT_ISO"
        -volid "Pardus-${PARDUS_VERSION}-Custom"
        -padding 0
        -compliance no_emul_toc
        -map "$ISO_DIR" /
        -chmod 0755 / --
        -boot_image isolinux dir=/isolinux
        -boot_image isolinux system_area=/usr/lib/ISOLINUX/isohdpfx.bin
        -boot_image any next
    )

    if [[ -n "$efi_img" ]]; then
        xorriso_args+=(
            -boot_image any efi_path="$efi_img"
            -boot_image isolinux partition_entry=gpt_basdat
        )
    else
        warn "EFI imajı bulunamadı. ISO yalnızca Legacy BIOS ile önyüklenebilir olabilir."
    fi

    xorriso "${xorriso_args[@]}"

    success "ISO oluşturuldu!"
}

# =============================================================================
# SON RAPOR
# =============================================================================
print_summary() {
    local iso_size
    iso_size=$(du -sh "$OUTPUT_ISO" | cut -f1)
    echo ""
    echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${GREEN}║         REMASTER TAMAMLANDI!                 ║${NC}"
    echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ISO Dosyası : ${CYAN}$OUTPUT_ISO${NC}"
    echo -e "  Boyut       : ${CYAN}$iso_size${NC}"
    echo ""
    echo -e "  USB'ye yazmak için:"
    echo -e "  ${YELLOW}sudo dd if=\"$OUTPUT_ISO\" of=/dev/sdX bs=4M status=progress oflag=sync${NC}"
    echo -e "  (sdX yerine USB cihazınızın adını girin)"
    echo ""
    echo -e "  Kurulum sırasında ${BOLD}Elle bölümleme${NC} seçeneğiyle"
    echo -e "  disk ve swap boyutunu serbestçe ayarlayabilirsiniz."
    echo ""
}

# =============================================================================
# TEMİZLİK
# =============================================================================
cleanup_on_error() {
    warn "Hata oluştu, temizlik yapılıyor..."
    mountpoint -q "$WORK_DIR/iso-mount" 2>/dev/null && umount "$WORK_DIR/iso-mount" || true
}
trap cleanup_on_error ERR

# =============================================================================
# ANA AKIŞ
# =============================================================================
main() {
    clear
    banner
    echo ""

    check_root
    check_deps
    detect_pardus
    detect_desktop
    select_output_dir
    download_iso
    extract_iso
    ask_cache_exclusion
    create_squashfs
    update_size_file
    update_md5
    build_iso
    print_summary
}

main "$@"
