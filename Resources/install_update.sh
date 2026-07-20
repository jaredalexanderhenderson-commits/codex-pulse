#!/bin/zsh
set -u

staged_app="$1"
target_app="$2"
app_pid="$3"
update_root="$4"
backup_app="${target_app}.update-backup-${app_pid}"

for _ in {1..200}; do
  if ! kill -0 "$app_pid" 2>/dev/null; then
    break
  fi
  sleep 0.1
done

if ! mv "$target_app" "$backup_app"; then
  /usr/bin/open -n "$target_app"
  exit 1
fi

if /usr/bin/ditto "$staged_app" "$target_app"; then
  /usr/bin/xattr -d com.apple.FinderInfo "$target_app" 2>/dev/null || true
  /usr/bin/xattr -d 'com.apple.fileprovider.fpfs#P' "$target_app" 2>/dev/null || true
fi

if /usr/bin/codesign --verify --deep --strict "$target_app"; then
  /usr/bin/open -n "$target_app"
  /bin/rm -rf "$backup_app" "$update_root"
  exit 0
fi

if [[ -e "$target_app" ]]; then
  /bin/rm -rf "$target_app"
fi
mv "$backup_app" "$target_app"
/usr/bin/open -n "$target_app"
exit 1
