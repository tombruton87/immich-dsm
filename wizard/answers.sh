    echo "ADMIN_EMAIL='$(printf '%s' "${wizard_admin_email:-}" | tr -cd 'A-Za-z0-9._+@-' | head -c 120)'"
    echo "ADMIN_NAME_B64='$(printf '%s' "${wizard_admin_name:-Admin}" | head -c 240 | base64 | tr -d '\n=' | tr '+/' '-_')'"
    echo "PHOTO_DIR_B64='$(printf '%s' "${wizard_photo_dir:-}" | head -c 300 | base64 | tr -d '\n=' | tr '+/' '-_')'"
    echo "ML_ON='$(if [ "${wizard_ml_off:-false}" = true ]; then echo 0; else echo 1; fi)'"
