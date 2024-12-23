-- noqa: disable=all
/* The transaction query to be run will be sent by the project calling the warehouse module.
This transaction will have all the necessary statements to do the warehouse reload, usually the following:

 - DELETE statement: in order to delete the data from the warehouse table so as to be replaced by the newest data

 - CALL statement: some projects like sellout need to call the staging layer to obtain the data needed (can be skipped)

 - INGEST statement: in order to insert the new data into the warehouse table

 - SELECT statement: to choose the data to be ingested

The following template will show an example of a transaction script that a project can use (but with variables)
*/

DELETE FROM `${project_id}.${warehouse_dataset}.t_${warehouse_name}_${schema_version}`
WHERE [delete filter to use];

CALL `${project_id}.${staging_dataset}.p_postmap_sellout_${warehouse_type}_${schema_version}`(); --noqa

INSERT INTO `${project_id}.${warehouse_dataset}.t_${warehouse_name}_${schema_version}`
SELECT * FROM [table/view to obtain data from] WHERE [select filter to use];
-- noqa: enable=all
