targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the environment that can be used as part of naming resource convention')
param environmentName string

@minLength(1)
@description('Primary location for all resources')
param location string

@description('Friendly name for your Azure AI resource')
param aiProjectFriendlyName string = 'Agents standard project resource'

@description('Description of your Azure AI resource displayed in Azure AI Foundry')
param aiProjectDescription string = 'A standard project resource required for the agent setup.'

@description('Set of tags to apply to all resources.')
param tags object = {}

@description('Array of models to deploy')
param models array = [
  {
    name: 'gpt-4o-mini'
    format: 'OpenAI'
    version: '2024-07-18'
    skuName: 'GlobalStandard'
    capacity: 140
  }
  {
    name: 'text-embedding-3-small'
    format: 'OpenAI'
    version: '1'
    skuName: 'GlobalStandard'
    capacity: 120
  }
]

@description('PostgreSQL admin password for the Container Apps deployment')
@secure()
param postgresPassword string

@description('Unique suffix for the resources')
@maxLength(13)
@minLength(0)
param uniqueSuffix string = uniqueString(subscription().id, 'rg-${environmentName}', location)

var resourceGroupName = toLower('rg-${environmentName}')

var defaultTags = {
  source: 'Azure AI Foundry Agents Service lab'
  'azd-env-name': toLower('${environmentName}')
}

var rootTags = union(defaultTags, tags)

// Create resource group
resource rg 'Microsoft.Resources/resourceGroups@2024-11-01' = {
  name: resourceGroupName
  location: location
  tags: rootTags
}

// Calculate the unique suffix
var aiProjectName = toLower('project-${uniqueSuffix}')
var foundryResourceName = toLower('foundry-${uniqueSuffix}')
var applicationInsightsName = toLower('appi-${uniqueSuffix}')

module applicationInsights 'application-insights.bicep' = {
  name: 'application-insights-deployment'
  scope: rg
  params: {
    applicationInsightsName: applicationInsightsName
    location: location
    tags: rootTags
  }
}

module foundry 'foundry.bicep' = {
  name: 'foundry-account-deployment'
  scope: rg
  params: {
    aiProjectName: aiProjectName
    location: location
    tags: rootTags
    foundryResourceName: foundryResourceName
  }
}

module foundryProject 'foundry-project.bicep' = {
  name: 'foundry-project-deployment'
  scope: rg
  params: {
    foundryResourceName: foundry.outputs.accountName
    aiProjectName: aiProjectName
    aiProjectFriendlyName: aiProjectFriendlyName
    aiProjectDescription: aiProjectDescription
    location: location
    tags: rootTags
  }
}

@batchSize(1)
module foundryModelDeployments 'foundry-model-deployment.bicep' = [for (model, index) in models: {
  name: 'foundry-model-deployment-${model.name}-${index}'
  scope: rg
  dependsOn: [
    foundryProject
  ]
  params: {
    foundryResourceName: foundry.outputs.accountName
    modelName: model.name
    modelFormat: model.format
    modelVersion: model.version
    modelSkuName: model.skuName
    modelCapacity: model.capacity
    tags: rootTags
  }
}]

module containerApps 'container-apps.bicep' = {
  name: 'container-apps-deployment'
  scope: rg
  params: {
    uniqueSuffix: uniqueSuffix
    location: location
    tags: rootTags
    logAnalyticsWorkspaceId: applicationInsights.outputs.logAnalyticsWorkspaceId
    postgresPassword: postgresPassword
  }
}

// Outputs
output subscriptionId string = subscription().subscriptionId
output resourceGroupName string = rg.name
output aiAccountName string = foundry.outputs.accountName
output aiProjectName string = foundryProject.outputs.aiProjectName
output projectsEndpoint string = '${foundry.outputs.endpoint}api/projects/${foundryProject.outputs.aiProjectName}'
output deployedModels array = [for (model, index) in models: {
  name: model.name
  deploymentName: foundryModelDeployments[index].outputs.modelDeploymentName
}]
output applicationInsightsName string = applicationInsights.outputs.applicationInsightsName
output applicationInsightsConnectionString string = applicationInsights.outputs.connectionString
output applicationInsightsInstrumentationKey string = applicationInsights.outputs.instrumentationKey
output acrName string = containerApps.outputs.acrName
output acrLoginServer string = containerApps.outputs.acrLoginServer
output containerAppsEnvName string = containerApps.outputs.containerAppsEnvName
output webAppUrl string = containerApps.outputs.webAppUrl
