# terraform-google-warehouse
Remote module to deploy warehouse resources

## Repository organisation
- **main.tf**: File with all the resources creation
- **reload-warehouse.yaml**: workflow yaml to launch warehouse tables reload
- **p_warehouse_reload.sql**: SQL transaction query used to define a procedure (to run the warehouse reload query)
- **transaction_script_template.sql**: template to understand transactions format in order to create the procedure

## Wareouse reload
The transaction reload script was added in the **version 2.0.0** of the module.

With this change, each project using the module must send a transaction query in order to create a reload procedure
(**check transaction_script_template.sql** for reference). This procedure will be invoked by a workflow and the transaction
will reload the desired warehouse table. In case of error in any of the steps, a rollback will be done and nothing
will change (neither deletions nor ingestions in the destination table)

If your project needs different transactions (For example: one for data providers and one for masterdata), you will have
to send the correct query to each of the module calls.

## Successful reload events
This module includes a feature which sends a pub/sub message whenever a warehouse is correctly reloaded. This can be useful
for use cases which are connected to the warehouse and need to launch any process after the reload is done. The use case can
subscribe to the pub/sub topic so that, In case the reload goes well and the warehouse is reloaded, the process will start,
while if there is any problem during the reload no process will be triggered (reducing costs)
