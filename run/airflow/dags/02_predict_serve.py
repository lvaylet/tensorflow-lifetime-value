# Copyright 2018 Google Inc. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#            http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import datetime, json, logging
from airflow import models
from airflow.operators.python_operator import PythonOperator
from airflow.hooks.base_hook import BaseHook
from airflow.contrib.operators import mlengine_operator
from airflow.contrib.operators import mlengine_operator_utils
from airflow.contrib.operators import dataflow_operator
from airflow.contrib.operators import gcs_to_bq
# TODO Add when Composer on v2.0 and more Hook
# from airflow.contrib.operators import gcs_list_operator
from airflow.contrib.hooks import GoogleCloudStorageHook
from airflow.utils import trigger_rule


def _get_project_id():
    """Get project ID from default GCP connection."""

    extras = BaseHook.get_connection('google_cloud_default').extra_dejson
    key = 'extra__google_cloud_platform__project'
    if key in extras:
        project_id = extras[key]
    else:
        raise ('Must configure project_id in google_cloud_default '
               'connection from Airflow Console')
    return project_id


PROJECT = _get_project_id()
REGION = models.Variable.get('region')
DF_ZONE = models.Variable.get('df_zone')
DF_TEMP = models.Variable.get('df_temp_location')
COMPOSER_BUCKET_NAME = models.Variable.get('COMPOSER_BUCKET_NAME')

#[START dag_predict_serve]
default_dag_args = {
    'start_date': datetime.datetime(2050, 1, 1),
    'schedule_internal': None,
    'provide_context': True,
    'dataflow_default_options': {
        'project': PROJECT,
        'zone': DF_ZONE,
        'tempLocation': DF_TEMP
    }
}

dag = models.DAG(
    'predict_serve',
    default_args=default_dag_args)
#[END dag_predict_serve]

#
# Runs prediction.
#

job_id = 'clv-{}'.format(datetime.datetime.now().strftime('%Y%m%d%H%M'))


def do_predict_clv(**kwargs):
    """ Runs a batch prediction on new data and saving the results as CSV into
    output_path.
    """
    gcs_prediction_intput = 'gs://{}/predictions/to_predict.csv'.format(COMPOSER_BUCKET_NAME)
    gcs_prediction_output = 'gs://{}/predictions/output'.format(COMPOSER_BUCKET_NAME)
    model_name = kwargs['dag_run'].conf.get('model_name')
    model_version = kwargs['dag_run'].conf.get('model_version')

    logging.info("Running prediction using {}:{}...".format(model_name,
                                                            model_version))

    mlengine_operator.MLEngineBatchPredictionOperator(
        task_id='predict_dnn',
        project_id=PROJECT,
        job_id=job_id,
        region=REGION,
        data_format='TEXT',
        input_paths=gcs_prediction_intput,
        output_path=gcs_prediction_output,
        model_name=model_name,
        version_name=model_version,
        # uri=gs://WHERE_MODEL_IS_IF_NOT_ML_ENGINE
        # runtime_version=TF_VERSION,
        dag=dag
    ).execute(kwargs)


t1 = PythonOperator(
    task_id='predict_clv', dag=dag, python_callable=do_predict_clv)


#
# Load the predictions from GCS to Datastore.
#

def do_load_to_datastore(**kwargs):
    """ Saves the predictions results into Datastore. Because there is no way to
    directly load a CSV to Datastore, we use Apache Beam on Dataflow with
    templates gs://dataflow-templates/latest/GCS_Text_to_Datastore.
    https://cloud.google.com/dataflow/docs/templates/provided-templates#gcstexttodatastore
    """
    gcs_prediction_output = 'gs://{}/predictions/output'.format(COMPOSER_BUCKET_NAME)
    template = 'gs://dataflow-templates/latest/GCS_Text_to_Datastore'

    df_template_params = {
        'textReadPattern': '{}/prediction.results*'.format(gcs_prediction_output),
        'javascriptTextTransformGcsPath': 'gs://{}/gcs_datastore_transform.js'.format(COMPOSER_BUCKET_NAME),
        'javascriptTextTransformFunctionName': 'from_prediction_output_to_datastore_object',
        'datastoreWriteProjectId': PROJECT,
        'errorWritePath': 'gs://{}/errors/serving_load'.format(COMPOSER_BUCKET_NAME)
    }

    dataflow_operator.DataflowTemplateOperator(
        task_id='gcs_predictions_df_transform',
        project_id=PROJECT,
        template=template,
        parameters=df_template_params,
        dag=dag
    ).execute(kwargs)


t2 = PythonOperator(
    task_id='load_to_datastore', dag=dag, python_callable=do_load_to_datastore)


#
# Loads the database dump from Cloud Storage to BigQuery
#

def do_list_predictions_files(**kwargs):
    """ Retrieves all the predictions files that should be loaded to BigQuery.
    Can not do a GoogleCloudStorageToBigQueryOperator directly due to the possible
    multiple files.
    """
    # List all relevant files
    # TODO Add when Composer is on Airflow 2.0
    # predictions_files = gcs_list_operator.GoogleCloudStorageListOperator(
    #     task_id='predictions_files',
    #     bucket=COMPOSER_BUCKET_NAME,
    #     prefix='predictions/output/prediction.results-'
    # )
    # TODO Remove when Composer on Airflow 2.0
    gcs = GoogleCloudStorageHook()
    predictions_files = gcs.list(
        bucket=COMPOSER_BUCKET_NAME,
        prefix='predictions/output/prediction.results-'
    )

    logging.info("Predictions files are: {}".format(predictions_files))

    # Create a variable that can be used in the next task
    kwargs['ti'].xcom_push(key='predictions_files', value=predictions_files)


def do_load_to_bq(**kwargs):
    """ Loads the prediction files to BigQuery using the list output from
    do_list_predictions_files.
    """
    dataset = kwargs['dag_run'].conf.get('dataset')

    # Reads files from the variables saved in the previous task
    ti = kwargs['ti']
    predictions_files = ti.xcom_pull(key='predictions_files',
                                     task_ids='list_predictions_files')

    gcs_to_bq.GoogleCloudStorageToBigQueryOperator(
        task_id="load_gcs_predictions_to_bigquery",
        bucket=COMPOSER_BUCKET_NAME,
        source_objects=predictions_files,
        schema_fields=[{
            'name': 'customer_id',
            'type': 'STRING'
        }, {
            'name': 'predicted_monetary',
            'type': 'FLOAT'
        }, {
            'name': 'predictions',
            'type': 'FLOAT'
        }],
        source_format="NEWLINE_DELIMITED_JSON",
        skip_leading_rows=1,
        destination_project_dataset_table="{}.{}.{}".format(PROJECT,
                                                            dataset,
                                                            'predictions'),
        create_disposition="CREATE_IF_NEEDED",
        write_disposition="WRITE_TRUNCATE",
        dag=dag
    ).execute(kwargs)


t3 = PythonOperator(
    task_id='list_predictions_files', dag=dag, python_callable=do_list_predictions_files)

t4 = PythonOperator(
    task_id='load_to_bq', dag=dag, python_callable=do_load_to_bq)

# How to link them
t1.set_downstream(t2)
t1.set_downstream(t3)
t3.set_downstream(t4)
