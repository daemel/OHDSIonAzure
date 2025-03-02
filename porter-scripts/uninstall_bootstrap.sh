#!/usr/bin/env bash
set -euo pipefail

ARM_CLIENT_ID=${ARM_CLIENT_ID:-my azure client id}
ARM_CLIENT_OBJECT_ID=${ARM_CLIENT_OBJECT_ID:-my azure client object id}
ARM_CLIENT_SECRET=${ARM_CLIENT_SECRET:-my azure client secret}
ARM_TENANT_ID=${ARM_TENANT_ID:-my azure tenant id}
ARM_SUBSCRIPTION_ID=${ARM_SUBSCRIPTION_ID:-my azure subscription id}
STORAGE_ACCOUNT_ACCESS_KEY=${STORAGE_ACCOUNT_ACCESS_KEY:-my storage account key}
RESOURCE_GROUP_NAME=${RESOURCE_GROUP_NAME:-mybootstraprg}
STORAGE_ACCOUNT_NAME=${STORAGE_ACCOUNT_NAME:-azurestorageaccountname}
CONTAINER_NAME=${CONTAINER_NAME:-mycontainername}
TFSTATE_FILE_NAME=${TFSTATE_FILE_NAME:-terraform.tfstate}
TF_WORKING_DIRECTORY=${TF_WORKING_DIRECTORY:-infra/terraform/bootstrap}
PREFIX=${PREFIX:-prefix}
ENVIRONMENT=${ENVIRONMENT:-env}
ADO_PAT=${ADO_PAT:-mypat}

while [ $# -gt 0 ]; do

   if [[ $1 == *"--"* ]]; then
        param="${1/--/}"
        declare "$param"="$2"
        # echo $1 $2 // Optional to see the parameter:value result
   fi

  shift
done

export ARM_CLIENT_ID="$ARM_CLIENT_ID"
export ARM_CLIENT_SECRET="$ARM_CLIENT_SECRET"
export ARM_TENANT_ID="$ARM_TENANT_ID"
export ARM_SUBSCRIPTION_ID="$ARM_SUBSCRIPTION_ID"
export ARM_ACCESS_KEY="$STORAGE_ACCOUNT_ACCESS_KEY"

az login --service-principal -u "$ARM_CLIENT_ID" -p "$ARM_CLIENT_SECRET" --tenant "$ARM_TENANT_ID"

# Create storage container if it doesn't exist
echo "Create Backend Azure Storage Container if it doesn't already exist"
az storage container create --name "$CONTAINER_NAME" --account-name "$STORAGE_ACCOUNT_NAME"

# Remove ADO VMSS Agent Extension
ADO_BOOTSTRAP_RESOURCE_GROUP_NAME="$PREFIX-$ENVIRONMENT-ado-bootstrap-omop-rg"
VMSS_NAME="$PREFIX-$ENVIRONMENT-ado-build-windows-vmss-agent"

echo "***** Remove Azure DevOps Pipeline Agent Extension *****"
EXTENSION_NAME='Microsoft.Azure.DevOps.Pipelines.Agent'
FOUND_EXTENSION_NAME=$(az vmss extension list -g "$ADO_BOOTSTRAP_RESOURCE_GROUP_NAME" --vmss-name "$VMSS_NAME" --query "[?name=='$EXTENSION_NAME']" | jq -r ".[].name")

if [ -z "$FOUND_EXTENSION_NAME" ]
then
     echo "Unable to find the extension $EXTENSION_NAME on VMSS $VMSS_NAME"
else
     echo "Able to find the extension $EXTENSION_NAME on VMSS $VMSS_NAME"
     az vmss extension delete --name "$EXTENSION_NAME" --resource-group "$ADO_BOOTSTRAP_RESOURCE_GROUP_NAME" --vmss-name "$VMSS_NAME"
fi

cd "$TF_WORKING_DIRECTORY"

# comment out prevent_destroy
sed -e '/prevent_destroy/s/^/#/g' -i azure_devops.tf

rm -rf .terraform

echo 'Bootstrap Terraform Init'
terraform init \
     -force-copy \
     -backend-config="resource_group_name=$RESOURCE_GROUP_NAME" \
     -backend-config="storage_account_name=$STORAGE_ACCOUNT_NAME" \
     -backend-config="container_name=$CONTAINER_NAME" \
     -backend-config="key=$TFSTATE_FILE_NAME"

echo 'Bootstrap Terraform Apply'
terraform apply -auto-approve -destroy \
     -var "client_object_id=$ARM_CLIENT_OBJECT_ID" \
     -var "prefix=$PREFIX" \
     -var "environment=$ENVIRONMENT" \
     -var "omop_password=$OMOP_PASSWORD" \
     -var "ado_pat=$ADO_PAT" \
     -var "admin_user_jumpbox=$ADMIN_USER_JUMPBOX" \
     -var "admin_password_jumpbox=$ADMIN_PASSWORD_JUMPBOX" \
     -var "admin_user=$ADMIN_USER" \
     -var "admin_password=$ADMIN_PASSWORD"

cd -

# Delete Backend Storage Container
az storage container delete --name "$CONTAINER_NAME" --account-name "$STORAGE_ACCOUNT_NAME"

# Delete Azure Key Vault
PORTER_BOOTSTRAP_AZURE_KEY_VAULT="$PREFIX-$ENVIRONMENT-kv"

# check if the key vault already exists
AZURE_KEY_VAULT_RESULT=$(az keyvault list -g "$RESOURCE_GROUP_NAME")
CURRENT_AZURE_KEY_VAULT=$(echo "$AZURE_KEY_VAULT_RESULT" | jq -r ".[] | select(.name==\"$PORTER_BOOTSTRAP_AZURE_KEY_VAULT\")")

if [ -z "$CURRENT_AZURE_KEY_VAULT" ]
then
     echo "Azure Key vault $PORTER_BOOTSTRAP_AZURE_KEY_VAULT not found, skipping Key Vault Clean up"
else
     echo "Azure Key vault $PORTER_BOOTSTRAP_AZURE_KEY_VAULT exists, cleaning up Key Vault"
     az keyvault delete \
          -n "$PORTER_BOOTSTRAP_AZURE_KEY_VAULT" \
          -g "$RESOURCE_GROUP_NAME"
     
     az keyvault purge --subscription "$ARM_SUBSCRIPTION_ID" -n "$PORTER_BOOTSTRAP_AZURE_KEY_VAULT"
fi
