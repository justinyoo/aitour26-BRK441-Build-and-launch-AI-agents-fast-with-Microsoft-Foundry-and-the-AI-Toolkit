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
        { name: 'postgres-url', value: 'postgresql://store_manager:${postgresPassword}@${postgresName}:5432/zava' }
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
          image: '${acr.properties.loginServer}/mcp-sales-analysis:latest'
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
        { name: 'postgres-url', value: 'postgresql://store_manager:${postgresPassword}@${postgresName}:5432/zava' }
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
          image: '${acr.properties.loginServer}/mcp-customer-sales:latest'
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
  tags: union(tags, { 'azd-service-name': 'mcp-customer-sales' })
  dependsOn: [
    postgres
  ]
}

// 4. Web App
resource webApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: webAppName
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
          image: '${acr.properties.loginServer}/web-app:latest'
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          env: [
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

// Outputs
output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer
output containerAppsEnvName string = containerAppsEnv.name
output webAppFqdn string = webApp.properties.configuration.ingress.fqdn
output webAppUrl string = 'https://${webApp.properties.configuration.ingress.fqdn}'
output postgresAppName string = postgres.name
output salesAnalysisAppName string = salesAnalysis.name
output customerSalesAppName string = customerSales.name
