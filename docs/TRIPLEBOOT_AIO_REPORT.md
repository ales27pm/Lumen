# Rapport de conception TripleBoot AIO

Ce rapport décrit la conception d’une clé USB **TripleBoot** automatisée, pré-chargée avec les installateurs d’Ubuntu, Windows et macOS. L’objectif est de démarrer sur une machine cible PC UEFI/GPT x86_64 et d’installer l’un de ces trois systèmes avec un minimum d’interactions manuelles.

Le script **TripleBoot AIO** du dépôt `ales27pm/TripleBoot` sert de base conceptuelle. Il orchestre le téléchargement des images, la préparation de la clé USB avec Ventoy et l’ajout d’un kit de secours macOS via OSX-KVM. Les étapes majeures sont le téléchargement et la vérification des ISO, l’installation de Ventoy avec prise en charge UEFI/Secure Boot, puis le *staging* des payloads dans l’arborescence Ventoy.

## Synthèse exécutive

- **Ubuntu et Windows** sont adaptés à une clé Ventoy multi-boot : les ISO peuvent être téléchargées, vérifiées ou fournies par l’utilisateur, puis copiées dans des dossiers dédiés de la partition de données Ventoy.
- **macOS** est le cas contraint : la création officielle d’un média d’installation requiert généralement un Mac et `createinstallmedia`. Sur Linux, le flux doit rester un *scaffold* OpenCore/OSX-KVM pour VM ou récupération, sans redistribution de fichiers Apple propriétaires.
- **L’installation sans surveillance** est réaliste pour Ubuntu avec `autoinstall`/cloud-init et pour Windows avec `Autounattend.xml`. macOS ne dispose pas d’un équivalent gratuit et natif hors infrastructure Apple/MDM.
- **La sécurité opérationnelle** doit être prioritaire : détection UEFI, état Secure Boot, refus d’écrire sur le disque racine actif, protection des partitions `LABEL=DATA`, sauvegarde EFI et confirmations explicites avant toute action destructive.

## 1. Contexte et objectifs

Le kit vise une clé USB multi-boot automatisée, dans l’esprit de Ventoy, contenant les installateurs d’Ubuntu, Windows et macOS. L’hôte de construction est typiquement une machine Linux Ubuntu/Debian disposant des outils système nécessaires : shell POSIX/Bash, utilitaires de partitionnement, outils de téléchargement, `wimtools`, QEMU/KVM et dépendances EFI.

Hypothèses matérielles :

- machine cible x86_64 64 bits ;
- firmware UEFI, sans support prioritaire du BIOS hérité ;
- table GPT ;
- RAM et stockage suffisants pour lancer les installateurs ;
- clé USB suffisamment grande pour contenir Ventoy, les ISO Ubuntu/Windows et les ressources macOS optionnelles.

Contraintes principales :

- **Sécurité** : aucune opération destructive sans option explicite comme `--yes-destroy` et confirmation textuelle ; pas d’écriture sur le disque racine actif ; blocage par défaut en présence de partitions utilisateur sensibles comme `DATA`.
- **Licence** : Ubuntu et les médias Windows sont distribuables selon leurs licences respectives, tandis que macOS reste soumis à l’EULA Apple. Le kit ne doit pas inclure de fichiers Apple propriétaires ni de clés de licence.
- **Automatisation pragmatique** : Ubuntu et Windows peuvent être rendus largement non assistés ; macOS doit être présenté comme un chemin manuel/officiel sur Mac ou expérimental en VM.

## 2. Architecture du pipeline automatisé

Le pipeline suit six phases.

1. **Préparation de l’hôte** : exécuter un diagnostic de type `installer-doctor` pour vérifier les dépendances (`curl`, `sha256sum`, `lsblk`, `sgdisk`, `wipefs`, `mkfs.vfat`, `wimlib-imagex`, `qemu-system-x86_64`, etc.).
2. **Téléchargement des installateurs** : récupérer Ubuntu depuis les miroirs officiels, Windows depuis une URL Microsoft ou un ISO local, et macOS depuis `softwareupdate` sur macOS ou via un flux OSX-KVM expérimental.
3. **Téléchargement de Ventoy** : récupérer l’archive Ventoy, extraire les outils et localiser `Ventoy2Disk.sh`.
4. **Préparation de la clé USB** : lancer l’installation Ventoy sur le disque USB, typiquement en GPT et avec l’option Secure Boot si requise.
5. **Staging des payloads** : monter la partition de données Ventoy et copier les ISO ou ressources dans une arborescence stable.
6. **Validation finale** : démonter proprement, afficher l’état de la clé et résumer les fichiers disponibles au démarrage.

Arborescence recommandée sur la partition de données Ventoy :

```text
/ISO/Ubuntu/        # ISO Ubuntu
/ISO/Windows/       # ISO Windows
/macOS/OSX-KVM/     # Ressources OpenCore/OSX-KVM optionnelles
/TripleBoot/        # Guides, README et métadonnées du kit
```

### Comparaison des chemins d’installation

| Critère | Ubuntu | Windows | macOS/OpenCore |
| --- | --- | --- | --- |
| Installation automatisable | Oui, via `autoinstall`/cloud-init | Oui, via `Autounattend.xml` | Non, hors solutions Apple/MDM ou étapes VM manuelles |
| Hôte de construction | Linux Ubuntu/Debian | Linux Ubuntu/Debian | Mac pour le média officiel, Linux+KVM pour VM expérimentale |
| Média sous Ventoy | ISO copiée directement | ISO copiée directement | Kit de secours/VM, pas un installateur macOS redistribué |
| Contraintes légales | Licence Ubuntu | Licence Windows requise à l’activation | EULA Apple, pas d’installation hors Mac officiel |
| Effort utilisateur | Faible après préparation | Moyen, surtout pour le fichier réponse | Élevé et majoritairement manuel |

## 3. Outils et paquets requis

Dépendances Linux recommandées :

- **Base système** : `bash`, `coreutils`, `util-linux`, `gawk`, `sed`, `grep`, `findutils`, `file`, `jq`.
- **Téléchargement et archives** : `curl`, `wget`, `unzip`, `zip`, `git`, `rsync`.
- **Partitionnement et fichiersystems** : `gdisk`, `parted`, `dosfstools`, `e2fsprogs`, `ntfs-3g`, `efibootmgr`, `mokutil`.
- **Diagnostic matériel** : `pciutils`, `usbutils`, `dmidecode`, `lshw`, `fwupd`, `nvme-cli`.
- **Windows** : `wimtools`, notamment `wimlib-imagex` pour les médias FAT32 traditionnels nécessitant de scinder `install.wim`.
- **macOS VM** : `qemu-system-x86`, `qemu-utils`, `ovmf`, éventuellement `dmg2img`, `genisoimage`, `virt-manager` et `libguestfs-tools`.

Commande indicative :

```bash
sudo apt-get install bash util-linux coreutils gawk sed grep findutils file jq curl wget unzip zip git rsync \
  gdisk parted dosfstools e2fsprogs ntfs-3g efibootmgr mokutil pciutils usbutils dmidecode \
  lshw acpica-tools fwupd nvme-cli wimtools qemu-system-x86 qemu-utils ovmf python3 python3-pip net-tools screen -y
```

## 4. Téléchargement et vérification des ISO

### Ubuntu

Ubuntu doit être récupéré depuis `releases.ubuntu.com` ou un miroir officiel. Le flux recommandé télécharge l’ISO et le fichier `SHA256SUMS`, puis exécute une vérification locale.

Exemple conceptuel :

```bash
scripts/tripleboot_aio.sh download-ubuntu --version 26.04 --edition desktop --arch amd64
```

L’empreinte SHA256 doit être vérifiée avant tout staging sur la clé USB. En cas d’échec, le pipeline doit refuser de copier l’image.

### Windows

Le pipeline accepte soit une URL d’ISO Windows, soit un fichier local fourni par l’utilisateur :

```bash
scripts/tripleboot_aio.sh download-windows --iso-url "URL_WINDOWS" --output-name Windows.iso
```

Les liens Microsoft pouvant être temporaires, le script doit traiter l’URL comme un input utilisateur et documenter la vérification d’authenticité par hash quand Microsoft publie une empreinte adaptée. Avec Ventoy, l’ISO Windows peut généralement être copiée directement. Pour une clé Windows FAT32 traditionnelle, `install.wim` doit être scindé si sa taille dépasse 4 Gio.

### macOS

Sur Mac, le chemin officiel repose sur `softwareupdate` puis `createinstallmedia` :

```bash
softwareupdate --fetch-full-installer --full-installer-version 15
sudo /Applications/Install\ macOS\ Sequoia.app/Contents/Resources/createinstallmedia --volume /Volumes/MyVolume --nointeraction
```

Sur Linux, le pipeline ne doit pas prétendre générer un installateur macOS complet et redistribuable. Il peut seulement préparer un kit de VM/récupération basé sur OpenCore/OSX-KVM, avec avertissement de licence et étapes manuelles.

## 5. Installation de Ventoy et préparation de la clé USB

Ventoy simplifie la préparation multi-boot : on installe son bootloader sur une clé, puis on copie les ISO sur la partition de données.

Workflow recommandé :

```bash
sudo scripts/tripleboot_aio.sh download-ventoy
sudo scripts/tripleboot_aio.sh prepare-usb-ventoy --usb-disk /dev/sdX --secure-boot --yes-destroy
```

Points de conception :

- utiliser GPT par défaut pour rester cohérent avec UEFI ;
- exposer une option Secure Boot, tout en documentant les limites et l’enrôlement éventuel de clés ;
- refuser les disques ambigus ou montés comme racine active ;
- isoler la phase destructive `prepare-usb-ventoy` de la phase non destructive `stage-tripleboot-usb` ;
- écrire un `README-FIRST.txt` sur la clé pour rappeler le contenu, les limites macOS et les commandes de reconstruction.

## 6. Options macOS : createinstallmedia vs. OSX-KVM

Deux chemins doivent être documentés clairement.

### Méthode officielle sur Mac

Un Mac compatible télécharge l’installateur complet et crée une clé officielle via `createinstallmedia`. Cette clé peut être indépendante de Ventoy, car Apple ne fournit pas un ISO macOS générique équivalent aux ISO Linux/Windows.

### Méthode Linux expérimentale

Un hôte Linux peut préparer un environnement OSX-KVM avec OpenCore, un disque virtuel et des scripts de lancement QEMU. Ce chemin sert au test ou à la récupération en VM, pas à une installation macOS automatisée sur PC. Il doit inclure :

- un avertissement EULA ;
- l’absence de fichiers Apple redistribués ;
- une séparation nette entre ressources OpenCore publiques et contenu Apple téléchargé par l’utilisateur ;
- une mention que l’adaptation matériel/OpenCore reste manuelle.

## 7. Installation sans surveillance après démarrage

### Ubuntu

Ubuntu peut utiliser un fichier `autoinstall` cloud-init pour définir utilisateur, partitionnement, réseau, paquets et commandes post-installation. Selon la stratégie Ventoy retenue, ce fichier peut être intégré à une ISO personnalisée ou référencé via un mécanisme compatible avec le menu/plugin Ventoy.

### Windows

Windows utilise un fichier réponse `Autounattend.xml`, habituellement placé à la racine du média d’installation ou dans un emplacement reconnu par Windows Setup. Il peut automatiser la sélection d’édition, le partitionnement, les paramètres régionaux, les comptes locaux et les commandes de post-installation.

### macOS

macOS ne fournit pas, pour ce scénario, d’équivalent simple et gratuit à `autoinstall` ou `Autounattend.xml`. Les solutions réellement automatisées relèvent plutôt de l’écosystème Apple administré, comme MDM/DEP, et restent hors périmètre du kit.

## 8. Sécurité et sauvegarde

Contrôles requis avant toute opération destructive :

- vérifier que l’hôte voit bien le disque USB attendu ;
- afficher marque, modèle, taille et partitions du disque cible ;
- bloquer si le disque cible est le disque racine actif ;
- bloquer par défaut si des partitions `LABEL=DATA` sont présentes ;
- exiger `--yes-destroy` et une confirmation textuelle ;
- recommander une sauvegarde complète et, pour les machines déjà multi-boot, une sauvegarde EFI ;
- rappeler de suspendre BitLocker ou de conserver la clé de récupération avant de modifier un environnement Windows.

Exemple d’intention destructive qui doit demander confirmation :

```bash
sudo scripts/tripleboot_aio.sh build-tripleboot-usb --usb-disk /dev/sdX --yes-destroy
```

Le script doit séparer les actions sûres des actions destructrices afin que les commandes de téléchargement, de vérification et de staging local puissent être testées sans risque.

## 9. Workflow recommandé

Exemple complet :

```bash
# 1. Vérifier l’environnement
sudo scripts/tripleboot_aio.sh installer-doctor

# 2. Télécharger ou enregistrer les installateurs
sudo scripts/tripleboot_aio.sh download-ubuntu --version 26.04 --edition desktop --arch amd64
sudo scripts/tripleboot_aio.sh download-windows --iso-url "URL_DE_VOTRE_ISO_WINDOWS"
# Sur Mac uniquement : sudo scripts/tripleboot_aio.sh download-macos --version 15

# 3. Télécharger Ventoy
sudo scripts/tripleboot_aio.sh download-ventoy

# 4. Préparer la clé Ventoy
sudo scripts/tripleboot_aio.sh prepare-usb-ventoy --usb-disk /dev/sdX --secure-boot --yes-destroy

# 5. Construire la clé TripleBoot complète
sudo scripts/tripleboot_aio.sh build-tripleboot-usb \
  --usb-disk /dev/sdX \
  --ubuntu-version 26.04 --ubuntu-edition desktop --ubuntu-arch amd64 \
  --windows-iso-url "URL_WINDOWS" \
  --include-osx-kvm \
  --secure-boot \
  --yes-destroy
```

À la fin, une commande de statut doit afficher :

- la table de partitions du disque USB ;
- le statut de montage/démontage ;
- la liste des ISO copiées ;
- les ressources macOS/OSX-KVM si présentes ;
- les avertissements licence et sécurité encore applicables.

## 10. Tests, cas limites et évolutions

Cas limites à couvrir :

- machine en BIOS hérité ;
- architecture ARM non prise en charge ;
- ISO corrompue ou hash absent ;
- lien Windows expiré ;
- clé USB lente ou instable ;
- partition de données Ventoy non montée ;
- conflit de labels ou de noms de volume ;
- Secure Boot activé avec politique firmware restrictive.

Plan d’évolution proposé :

- **v0.4.x** : stabiliser le pipeline Ventoy, gérer les mises à jour Ventoy, améliorer les messages d’erreur et documenter des exemples `Autounattend.xml`.
- **v0.5.x** : ajouter les plugins Ventoy, persistance Linux, profils de partitionnement Windows et meilleure orchestration OSX-KVM.
- **v0.6+** : proposer un assistant interactif, internationaliser la documentation, ajouter des journaux structurés et valider le pipeline dans des VM de test.

Tests recommandés :

- tests unitaires des fonctions de parsing, détection disque, montage et copie ;
- tests d’intégration sur image disque ou clé USB de test ;
- boot réel ou virtuel des ISO Ubuntu et Windows via Ventoy ;
- test négatif confirmant qu’un disque racine actif ou un volume `DATA` bloque les commandes destructrices ;
- revue manuelle du flux macOS pour confirmer l’absence de redistribution de contenu Apple.

## Sources de référence à vérifier lors de l’implémentation

Les références exactes doivent être vérifiées au moment de l’implémentation, car les versions, URLs et recommandations changent régulièrement :

- documentation Ubuntu sur les images de publication, `SHA256SUMS` et `autoinstall` ;
- documentation Microsoft sur Windows Setup et `Autounattend.xml` ;
- documentation Apple Support sur `createinstallmedia` ;
- documentation Ventoy, notamment `Ventoy2Disk.sh`, GPT et Secure Boot ;
- documentation `wimlib-imagex` pour le découpage des fichiers WIM ;
- documentation et scripts du projet TripleBoot utilisé comme base de conception.
