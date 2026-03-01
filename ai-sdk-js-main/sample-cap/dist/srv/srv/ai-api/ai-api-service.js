import { DeploymentApi } from '@sap-ai-sdk/ai-api';
export default class AiApiService {
    async getDeployments() {
        const resourceGroup = process.env.AICORE_RESOURCE_GROUP?.trim() || 'default';
        const maxDeployments = Number.parseInt(process.env.AI_API_MAX_DEPLOYMENTS ?? '200', 10);
        try {
            const response = await DeploymentApi.deploymentQuery({}, { 'AI-Resource-Group': resourceGroup }).execute();
            const resources = (response.resources ?? []).slice(0, Number.isFinite(maxDeployments) && maxDeployments > 0 ? maxDeployments : 200);
            return JSON.stringify(resources);
        }
        catch (error) {
            const message = error instanceof Error ? error.message : String(error);
            throw new Error(`Failed to fetch AI Core deployments: ${message}`);
        }
    }
}
//# sourceMappingURL=ai-api-service.js.map