// container-apps.bicep
// This file creates the Azure Container Apps infrastructure:
// - Azure Container Registry (ACR)
// - Container Apps Environment
// - 4 Container Apps: Web App, Sales Analysis MCP, Customer Sales MCP, PostgreSQL

// Parameters
@description('Unique suffix for the resources')
param uniqueSuffix string

@description('Location for all resources')
param location string

@description('Set of tags to apply to all resources.')
param tags object = {}

@description('Log Analytics workspace ID for the Container Apps Environment')
param logAnalyticsWorkspaceId string

@description('PostgreSQL admin password')
@secure()
param postgresPassword string

@description('Azure AI Foundry project endpoint')
param aiFoundryEndpoint string

@description('Model deployment name')
param modelDeploymentName string

@description('Azure AI Foundry account name for RBAC')
param foundryAccountName string

// URL-encode the password so special chars (like @) don't break the connection string
var postgresUrlEncodedPassword = uriComponent(postgresPassword)

// Resource names
var acrName = toLower('acrzava${uniqueSuffix}')
var containerAppsEnvName = toLower('cae-${uniqueSuffix}')
var webAppName = toLower('ca-web-app-${uniqueSuffix}')
var salesAnalysisName = toLower('ca-mcp-sales-${uniqueSuffix}')
var customerSalesName = toLower('ca-mcp-customer-${uniqueSuffix}')
var postgresName = toLower('ca-postgres-${uniqueSuffix}')

// Azure Container Registry
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: true
  }
  tags: tags
}

// Container Apps Environment
resource containerAppsEnv 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: containerAppsEnvName
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: reference(logAnalyticsWorkspaceId, '2023-09-01').customerId
        sharedKey: listKeys(logAnalyticsWorkspaceId, '2023-09-01').primarySharedKey
      }
    }
  }
  tags: tags
}

// 1. PostgreSQL Container App
resource postgres 'Microsoft.App/containerApps@2024-03-01' = {
  name: postgresName
  location: location
  properties: {
    managedEnvironmentId: containerAppsEnv.id
    configuration: {
      secrets: [
        { name: 'postgres-password', value: postgresPassword }
      ]
      ingress: {
        external: false
        targetPort: 5432
        transport: 'tcp'
        exposedPort: 5432
      }
    }
    template: {
      containers: [
        {
          name: 'postgres'
          image: 'pgvector/pgvector:pg17'
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            { name: 'POSTGRES_DB', value: 'zava' }
            { name: 'POSTGRES_USER', value: 'store_manager' }
            { name: 'POSTGRES_PASSWORD', secretRef: 'postgres-password' }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
  tags: tags
}

// 2. Sales Analysis MCP Server
module salesAnalysisFetchLatestImage './fetch-container-image.bicep' = {
  name: 'sales-analyst-fetch-image'
  params: {
    exists: false
    name: salesAnalysisName
  }
}

resource salesAnalysis 'Microsoft.App/containerApps@2024-03-01' = {
  name: salesAnalysisName
  location: location
  properties: {
    managedEnvironmentId: containerAppsEnv.id
    configuration: {
      registries: [
        {
          server: acr.properties.loginServer
          username: acr.listCredentials().username
          passwordSecretRef: 'acr-password'
        }
      ]
      secrets: [
        { name: 'acr-password', value: acr.listCredentials().passwords[0].value }
        #disable-next-line BCP225
        { name: 'postgres-url', value: 'postgresql://store_manager:${postgresUrlEncodedPassword}@${postgresName}:5432/zava?sslmode=disable' }
      ]
      ingress: {
        external: false
        targetPort: 8000
        transport: 'http'
      }
    }
    template: {
      containers: [
        {
          name: 'mcp-sales-analysis'
          image: salesAnalysisFetchLatestImage.outputs.?containers[?0].?image ?? 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          env: [
            { name: 'POSTGRES_URL', secretRef: 'postgres-url' }
          ]
        }
      ]
      scale: {
        minReplicas: 0
        maxReplicas: 3
      }
    }
  }
  tags: union(tags, { 'azd-service-name': 'mcp-sales-analysis' })
  dependsOn: [
    postgres
  ]
}

// 3. Customer Sales MCP Server
module customerSalesFetchLatestImage './fetch-container-image.bicep' = {
  name: 'customer-sales-fetch-image'
  params: {
    exists: false
    name: customerSalesName
  }
}

resource customerSales 'Microsoft.App/containerApps@2024-03-01' = {
  name: customerSalesName
  location: location
  properties: {
    managedEnvironmentId: containerAppsEnv.id
    configuration: {
      registries: [
        {
          server: acr.properties.loginServer
          username: acr.listCredentials().username
          passwordSecretRef: 'acr-password'
        }
      ]
      secrets: [
        { name: 'acr-password', value: acr.listCredentials().passwords[0].value }
        #disable-next-line BCP225
        { name: 'postgres-url', value: 'postgresql://store_manager:${postgresUrlEncodedPassword}@${postgresName}:5432/zava?sslmode=disable' }
      ]
      ingress: {
        external: false
        targetPort: 8000
        transport: 'http'
      }
    }
    template: {
      containers: [
        {
          name: 'mcp-customer-sales'
          image: customerSalesFetchLatestImage.outputs.?containers[?0].?image ?? 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          env: [
            { name: 'POSTGRES_URL', secretRef: 'postgres-url' }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 3
      }
    }
  }
  tags: union(tags, { 'azd-service-name': 'mcp-customer-sales' })
  dependsOn: [
    postgres
  ]
}

// 4. Web App
module webAppFetchLatestImage './fetch-container-image.bicep' = {
  name: 'web-app-fetch-image'
  params: {
    exists: false
    name: webAppName
  }
}

resource webApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: webAppName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    managedEnvironmentId: containerAppsEnv.id
    configuration: {
      registries: [
        {
          server: acr.properties.loginServer
          username: acr.listCredentials().username
          passwordSecretRef: 'acr-password'
        }
      ]
      secrets: [
        { name: 'acr-password', value: acr.listCredentials().passwords[0].value }
      ]
      ingress: {
        external: true
        targetPort: 8000
        transport: 'http'
      }
    }
    template: {
      containers: [
        {
          name: 'web-app'
          image: webAppFetchLatestImage.outputs.?containers[?0].?image ?? 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          env: [
            { name: 'AZURE_AI_FOUNDRY_ENDPOINT', value: aiFoundryEndpoint }
            { name: 'MODEL_DEPLOYMENT_NAME', value: modelDeploymentName }
            { name: 'MCP_SALES_ANALYSIS_URL', value: 'http://${salesAnalysisName}' }
            { name: 'MCP_CUSTOMER_SALES_URL', value: 'http://${customerSalesName}' }
          ]
        }
      ]
      scale: {
        minReplicas: 0
        maxReplicas: 3
      }
    }
  }
  tags: union(tags, { 'azd-service-name': 'web-app' })
  dependsOn: [
    salesAnalysis
    customerSales
  ]
}

// var cognitiveServicesOpenAIUserRoleId = '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
// var azureAIDeveloperRoleId = '64702f94-c441-49e6-a78b-ef80e0188fee'
// Azure AI User role scoped to the Foundry account (includes agents/write data action)
var azureAIUserRoleId = '53ca6127-db72-4b80-b1b0-d745d6d5456d'

resource foundryAccount 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: foundryAccountName
}

resource webAppRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(foundryAccount.id, webApp.id, azureAIUserRoleId)
  scope: foundryAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', azureAIUserRoleId)
    principalId: webApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Outputs
output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer
output containerAppsEnvName string = containerAppsEnv.name
output webAppFqdn string = webApp.properties.configuration.ingress.fqdn
output webAppUrl string = 'https://${webApp.properties.configuration.ingress.fqdn}'
output postgresAppName string = postgres.name
output salesAnalysisAppName string = salesAnalysis.name
output customerSalesAppName string = customerSales.name
output webAppPrincipalId string = webApp.identity.principalId
