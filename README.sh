#!/usr/bin/env bash

# Setup
# 1. Set variables
export PROJECT=$(gcloud config get-value project 2> /dev/null)
export BUCKET=gs://${PROJECT}_data_final
export REGION=europe-west1
export DATASET_NAME=ltv  # the name of the BigQuery dataset

#export COMPOSER_NAME="clv-final"
export COMPOSER_NAME=tst-rlt-a3ct-dev  # reuse existing Cloud Composer
#export COMPOSER_BUCKET_NAME=${PROJECT}_composer_final
# FIXME How to set Cloud Composer to use an existing bucket? If not possible, create Cloud Composer first and save
#       bucket name to env variable.
export COMPOSER_BUCKET_NAME=europe-west1-tst-rlt-a3ct-d-856627c5-bucket  # reuse Cloud Composer bucket
export COMPOSER_BUCKET=gs://${COMPOSER_BUCKET_NAME}
export DF_STAGING=${COMPOSER_BUCKET}/dataflow_staging
export DF_ZONE=${REGION}-b
export SQL_MP_LOCATION=sql  # the local folder (under preparation/) containing the SQL requests used by the DAGs

export LOCAL_FOLDER=$(pwd)

# 2. Create workspace
gsutil mb -l ${REGION} -p ${PROJECT} ${BUCKET}
gsutil mb -l ${REGION} -p ${PROJECT} ${COMPOSER_BUCKET}
bq --location=EU mk --dataset ${PROJECT}:${DATASET_NAME}

# 3. Copy useful data

# a. Copy the raw dataset (19.8 GiB)
gsutil cp gs://solutions-public-assets/ml-clv/db_dump.csv ${BUCKET}
gsutil cp ${BUCKET}/db_dump.csv ${COMPOSER_BUCKET}

# b. Copy the dataset to be predicted. Replace with your own.
gsutil cp clv_mle/to_predict.json ${BUCKET}/predictions/
gsutil cp ${BUCKET}/predictions/to_predict.json ${COMPOSER_BUCKET}/predictions/

# 4. Optional - Create Machine Learning Engine packaged file
# If you make changes to any of the Python files in clv_mle, you need to recreate the packaged files usable by ML
# Engine.
cd ${LOCAL_FOLDER}/clv_mle
rm -rf clv_ml_engine.egg-info/
rm -rf dist
python setup.py sdist
gsutil cp dist/* ${COMPOSER_BUCKET}/code/  # clv_ml_engine-0.1.tar.gz - 10.78 KB

# Set up Cloud Composer
#
# 1. Enable the required APIs
gcloud services enable dataflow.googleapis.com  # Dataflow API
gcloud services enable composer.googleapis.com  # Cloud Composer API
gcloud services enable ml.googleapis.com        # Cloud Machine Learning Engine
#
# 2. Create a service account
#
# Creating a service account is important to make sure that your Cloud Composer instance can perform the required tasks
# within BigQuery, ML Engine, Dataflow, Cloud Storage and Datastore.
gcloud iam service-accounts create composer --display-name composer --project ${PROJECT}

gcloud projects add-iam-policy-binding ${PROJECT} \
--member serviceAccount:composer@${PROJECT}.iam.gserviceaccount.com \
--role roles/composer.worker

gcloud projects add-iam-policy-binding ${PROJECT} \
--member serviceAccount:composer@${PROJECT}.iam.gserviceaccount.com \
--role roles/bigquery.dataEditor

gcloud projects add-iam-policy-binding ${PROJECT} \
--member serviceAccount:composer@${PROJECT}.iam.gserviceaccount.com \
--role roles/bigquery.jobUser

gcloud projects add-iam-policy-binding ${PROJECT} \
--member serviceAccount:composer@${PROJECT}.iam.gserviceaccount.com \
--role roles/storage.admin

gcloud projects add-iam-policy-binding ${PROJECT} \
--member serviceAccount:composer@${PROJECT}.iam.gserviceaccount.com \
--role roles/ml.developer

gcloud projects add-iam-policy-binding ${PROJECT} \
--member serviceAccount:composer@${PROJECT}.iam.gserviceaccount.com \
--role roles/dataflow.developer

gcloud projects add-iam-policy-binding ${PROJECT} \
--member serviceAccount:composer@${PROJECT}.iam.gserviceaccount.com \
--role roles/compute.viewer

gcloud projects add-iam-policy-binding ${PROJECT} \
--member serviceAccount:composer@${PROJECT}.iam.gserviceaccount.com \
--role roles/storage.objectAdmin

# 3. Create a composer instance with the service account
gcloud composer environments create ${COMPOSER_NAME} \
--location ${REGION}  \
--zone ${REGION}-b \
--machine-type n1-standard-1 \
--service-account=composer@${PROJECT}.iam.gserviceaccount.com \
--network "main-euw1"

# 4. Make SQL files available to the DAG
# There are various ways of calling BigQuery queries. This solutions leverages BigQuery files directly. For them to be
# accessible by the DAGs, they need to be in the same folder.
# The following command line, copies the entire sql folder as a subfolder in the Airflow dags folder.
cd ${LOCAL_FOLDER}/preparation

gcloud composer environments storage dags import \
--environment ${COMPOSER_NAME} \
--source  ${SQL_MP_LOCATION} \
--location ${REGION} \
--project ${PROJECT}

# 5. Other files
# Some files are important when running the DAG. They can be saved in the data folder:

# a. The BigQuery schema file used to load data into BigQuery
cd ${LOCAL_FOLDER}
gsutil cp ./run/airflow/schema_source.json ${COMPOSER_BUCKET}

# b. A Javascript file used by the Dataflow template for processing.
gsutil cp ./run/airflow/gcs_datastore_transform.js ${COMPOSER_BUCKET}

# 6. Set environment variables

# Install kubectl
gcloud components install kubectl

# a. Region where things happen
gcloud composer environments run ${COMPOSER_NAME} variables --location ${REGION} \
-- \
--set region ${REGION}

# b. Staging location for Dataflow
gcloud composer environments run ${COMPOSER_NAME} variables --location ${REGION} \
-- \
--set df_temp_location ${DF_STAGING}

# c. Zone where Dataflow should run
gcloud composer environments run ${COMPOSER_NAME} variables --location ${REGION} \
-- \
--set df_zone ${DF_ZONE}

# d. BigQuery working dataset
gcloud composer environments run ${COMPOSER_NAME} variables --location ${REGION} \
-- \
--set dataset ${DATASET_NAME}

# e. Composer bucket
gcloud composer environments run ${COMPOSER_NAME} variables --location ${REGION} \
-- \
--set composer_bucket_name ${COMPOSER_BUCKET_NAME}

# Import DAGs
# You need to run this for all your dag files. This solution only has two located in the run/airflow/dags folder.

gcloud composer environments storage dags import \
--environment ${COMPOSER_NAME} \
--source run/airflow/dags/01_build_train_deploy.py \
--location ${REGION} \
--project ${PROJECT}

gcloud composer environments storage dags import \
--environment ${COMPOSER_NAME} \
--source run/airflow/dags/02_predict_serve.py \
--location ${REGION} \
--project ${PROJECT}

# Run DAGs

gcloud composer environments run ${COMPOSER_NAME} \
--project ${PROJECT} \
--location ${REGION} \
trigger_dag \
-- \
build_train_deploy \
--conf '{"model_type":"dnn_model", "project":"'${PROJECT}'", "dataset":"'${DATASET_NAME}'", "threshold_date":"2013-01-31", "predict_end":"2013-07-31", "model_name":"dnn_airflow", "model_version":"v1", "tf_version":"1.10", "max_monetary":"20000"}'

gcloud composer environments run ${COMPOSER_NAME} \
--project ${PROJECT} \
--location ${REGION} \
trigger_dag \
-- \
predict_serve \
--conf '{"model_name":"dnn_airflow", "model_version":"v1", "dataset":"ltv"}'

#[2018-11-23 10:40:10,637] {base_task_runner.py:98} INFO - Subtask: [2018-11-23 10:40:10,636] {gcp_mlengine_hook.py:117} ERROR - Failed to create MLEngine job: <HttpError 404 when requesting https://ml.googleapis.com/v1/projects/devops-terraform-deployer/jobs?alt=json returned "Field: prediction_input.version_name Error: The model resource: "dnn_airflow" was not found. Please create the Cloud ML model resource first by using 'gcloud ml-engine models create dnn_airflow'.">
# gcloud ml-engine models create dnn_airflow
