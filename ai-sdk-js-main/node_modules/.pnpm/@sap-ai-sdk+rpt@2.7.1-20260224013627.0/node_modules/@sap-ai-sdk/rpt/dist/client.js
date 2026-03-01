import { getFoundationModelDeploymentId, getResourceGroup } from '@sap-ai-sdk/ai-api/internal.js';
import { RptApi } from './internal.js';
/**
 * Representation of an RPT client to make predictions.
 * @experimental This class is experimental and may change at any time without prior notice.
 */
export class RptClient {
    modelDeployment;
    destination;
    /**
     * Creates an instance of the RPT client.
     * @param modelDeployment - This configuration is used to retrieve a deployment. Depending on the configuration use either the given deployment ID or the model name to retrieve matching deployments. If model and deployment ID are given, the model is verified against the deployment.
     * @param destination - The destination to use for the request.
     */
    constructor(modelDeployment = 'sap-rpt-1-small', destination) {
        this.modelDeployment = modelDeployment;
        this.destination = destination;
    }
    /**
     * Predict based on data schema and prediction data.
     * Prefer using this method when the data schema is known.
     * @param dataSchema - Prediction data follows this schema. When using TypeScript, the data schema type is used to infer the types of the prediction data. In that case, the data schema must be provided as a constant (`as const`).
     * @param predictionData - Data to base prediction on.
     * @returns Prediction response.
     */
    async predictWithSchema(dataSchema, predictionData) {
        return this.executePrediction(predictionData, dataSchema);
    }
    /**
     * Predict based on prediction data with data schema inferred.
     * Prefer using `predictWithSchema` when the data schema is known.
     * @param predictionData - Data to base prediction on.
     * @returns Prediction response.
     */
    async predictWithoutSchema(predictionData) {
        return this.executePrediction(predictionData);
    }
    /**
     * Predict based on data schema and prediction data.
     * @param predictionData - Data to base prediction on.
     * @param dataSchema - Prediction data follows this schema.
     * @returns Prediction response.
     */
    async executePrediction(predictionData, dataSchema) {
        const deploymentId = await getFoundationModelDeploymentId(this.modelDeployment, 'aicore-sap', this.destination);
        const resourceGroup = getResourceGroup(this.modelDeployment);
        const body = {
            data_schema: dataSchema
                ? Object.fromEntries(dataSchema.map(({ name, ...schemaFieldConfig }) => [
                    name,
                    schemaFieldConfig
                ]))
                : null,
            ...predictionData
        };
        return RptApi.predict(body)
            .setBasePath(`/inference/deployments/${deploymentId}`)
            .addCustomHeaders({ 'ai-resource-group': resourceGroup || 'default' })
            .execute(this.destination);
    }
}
//# sourceMappingURL=client.js.map