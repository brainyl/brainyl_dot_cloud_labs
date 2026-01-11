'use client'

import React from 'react'
import { useRouter } from 'next/navigation'
import {
  Box,
  Container,
  Heading,
  Text,
  Button,
  VStack,
  HStack,
  Card,
  CardBody,
  Badge,
  useColorModeValue,
  Spinner,
  Alert,
  AlertIcon,
  Code,
  Divider,
} from '@chakra-ui/react'

interface Session {
  session_id: string
  region: string
  status: string
  browser_id?: string
  agentcore_session_id?: string
}

export default function AgentCoreDemoPage() {
  const router = useRouter()
  const [session, setSession] = React.useState<Session | null>(null)
  const [liveViewUrl, setLiveViewUrl] = React.useState<string | null>(null)
  const [loading, setLoading] = React.useState(false)
  const [automationRunning, setAutomationRunning] = React.useState(false)
  const [error, setError] = React.useState<string | null>(null)
  const [logs, setLogs] = React.useState<string[]>([])

  const bgColor = useColorModeValue('gray.50', 'gray.900')
  const cardBg = useColorModeValue('white', 'gray.800')

  const addLog = (message: string) => {
    setLogs(prev => [...prev, `${new Date().toLocaleTimeString()}: ${message}`])
  }

  const createSession = async () => {
    setLoading(true)
    setError(null)
    addLog('Creating browser session...')

    try {
      const response = await fetch('http://localhost:8100/browser-session/v1/sessions', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-Tenant-ID': 'demo_tenant',
          'X-User-ID': 'demo_user',
        },
        body: JSON.stringify({
          tenant_id: 'demo_tenant',
          user_id: 'demo_user',
          region: 'us-west-2',
          ttl_seconds: 3600,
        }),
      })

      if (!response.ok) {
        throw new Error(`Failed to create session: ${response.statusText}`)
      }

      const data = await response.json()
      setSession(data)
      addLog(`✅ Session created: ${data.session_id}`)
      addLog(`Browser ID: ${data.browser_id}`)
      
    } catch (err: any) {
      setError(err.message)
      addLog(`❌ Error: ${err.message}`)
    } finally {
      setLoading(false)
    }
  }

  const getLiveView = async () => {
    if (!session) return

    setLoading(true)
    setError(null)
    addLog('Getting live view URL...')

    try {
      const response = await fetch(
        `http://localhost:8100/browser-session/v1/sessions/${session.session_id}/live-view/presign`,
        {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'X-Tenant-ID': 'demo_tenant',
            'X-User-ID': 'demo_user',
          },
          body: JSON.stringify({ ttl_seconds: 300 }),
        }
      )

      if (!response.ok) {
        throw new Error(`Failed to get live view: ${response.statusText}`)
      }

      const data = await response.json()
      setLiveViewUrl(data.presigned_url)
      addLog('✅ Live view URL generated')
      addLog('Opening DCV viewer...')
      
      // Navigate to viewer page
      const viewerUrl = `/viewer?sessionId=${session.session_id}`
      window.open(viewerUrl, '_blank', 'width=1600,height=900')
      
    } catch (err: any) {
      setError(err.message)
      addLog(`❌ Error: ${err.message}`)
    } finally {
      setLoading(false)
    }
  }

  const startAutomation = async () => {
    if (!session) return

    setAutomationRunning(true)
    setError(null)
    addLog('🤖 Starting automation agent...')
    addLog('👀 Watch the live view window to see the agent work!')

    try {
      const response = await fetch(
        `http://localhost:8100/browser-session/v1/sessions/${session.session_id}/automation/run`,
        {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
          },
        }
      )

      if (!response.ok) {
        const errorData = await response.json().catch(() => ({}))
        throw new Error(errorData.detail || `Failed to start automation: ${response.statusText}`)
      }

      const data = await response.json()
      addLog('✅ Automation started successfully!')
      addLog('')
      addLog('🎬 The AI agent will perform these steps:')
      addLog('   1. Visit Example.com')
      addLog('   2. Navigate to Wikipedia')
      addLog('   3. Search for "Artificial Intelligence"')
      addLog('   4. Scroll through the article')
      addLog('   5. Visit AWS website')
      addLog('   6. Final stop at Google')
      addLog('')
      addLog('👀 Watch the live view window to see the magic happen!')
      addLog('⏱️  Automation will take ~20-30 seconds to complete.')
      
    } catch (err: any) {
      const errorMsg = err.message || 'Failed to start automation'
      setError(errorMsg)
      addLog(`❌ Error: ${errorMsg}`)
    } finally {
      setAutomationRunning(false)
    }
  }

  return (
    <Box minH="100vh" bg={bgColor} py={12}>
      <Container maxW="6xl">
        {/* Header */}
        <VStack spacing={4} mb={8}>
          <Badge colorScheme="purple" fontSize="md" px={3} py={1} rounded="full">
            AWS AgentCore Demo
          </Badge>
          <Heading size="2xl" textAlign="center">
            Live Browser Automation Demo
          </Heading>
          <Text fontSize="lg" color="gray.600" textAlign="center" maxW="2xl">
            Watch AI agents work in real-time using AWS AgentCore's DCV streaming and CDP automation
          </Text>
        </VStack>

        {/* Error Alert */}
        {error && (
          <Alert status="error" mb={6} borderRadius="md">
            <AlertIcon />
            {error}
          </Alert>
        )}

        {/* Main Content */}
        <HStack spacing={6} align="start">
          {/* Control Panel */}
          <Card bg={cardBg} flex="1">
            <CardBody>
              <VStack spacing={6} align="stretch">
                <Heading size="md">Control Panel</Heading>
                
                <Divider />

                {/* Step 1: Create Session */}
                <Box>
                  <Text fontWeight="bold" mb={2}>Step 1: Create Browser Session</Text>
                  <Text fontSize="sm" mb={3} color="gray.600">
                    Spin up an AWS-managed Chrome browser in us-west-2
                  </Text>
                  <Button
                    colorScheme="blue"
                    onClick={createSession}
                    isLoading={loading && !session}
                    loadingText="Creating..."
                    isDisabled={!!session}
                    width="full"
                  >
                    {session ? '✅ Session Created' : 'Create Browser'}
                  </Button>
                  {session && (
                    <Box mt={2} p={2} bg="gray.100" borderRadius="md">
                      <Code fontSize="xs">{session.session_id}</Code>
                    </Box>
                  )}
                </Box>

                <Divider />

                {/* Step 2: View Live */}
                <Box>
                  <Text fontWeight="bold" mb={2}>Step 2: Open Live View</Text>
                  <Text fontSize="sm" mb={3} color="gray.600">
                    Stream the browser display to your local browser via DCV
                  </Text>
                  <Button
                    colorScheme="green"
                    onClick={getLiveView}
                    isDisabled={!session}
                    isLoading={loading && !!session}
                    loadingText="Getting URL..."
                    width="full"
                  >
                    {liveViewUrl ? '🎥 View in New Window' : 'Get Live View'}
                  </Button>
                </Box>

                <Divider />

                {/* Step 3: Start Automation */}
                <Box>
                  <Text fontWeight="bold" mb={2}>Step 3: Start Automation</Text>
                  <Text fontSize="sm" mb={3} color="gray.600">
                    Run the automation agent and watch it work in the live view
                  </Text>
                  <Button
                    colorScheme="purple"
                    onClick={startAutomation}
                    isDisabled={!session}
                    isLoading={automationRunning}
                    width="full"
                  >
                    🤖 Start Automation
                  </Button>
                </Box>
              </VStack>
            </CardBody>
          </Card>

          {/* Activity Log */}
          <Card bg={cardBg} flex="1">
            <CardBody>
              <VStack spacing={4} align="stretch">
                <Heading size="md">Activity Log</Heading>
                <Divider />
                <Box
                  maxH="500px"
                  overflowY="auto"
                  p={3}
                  bg="gray.900"
                  borderRadius="md"
                  fontFamily="monospace"
                  fontSize="sm"
                  color="green.300"
                >
                  {logs.length === 0 ? (
                    <Text color="gray.500">No activity yet...</Text>
                  ) : (
                    logs.map((log, idx) => (
                      <Text key={idx} mb={1}>
                        {log}
                      </Text>
                    ))
                  )}
                </Box>
              </VStack>
            </CardBody>
          </Card>
        </HStack>

        {/* Architecture Info */}
        <Card bg={cardBg} mt={6}>
          <CardBody>
            <Heading size="sm" mb={3}>How It Works</Heading>
            <VStack spacing={2} align="start" fontSize="sm">
              <Text>
                <strong>Browser Session API:</strong> FastAPI service wrapping AgentCore BrowserClient
              </Text>
              <Text>
                <strong>AWS AgentCore:</strong> Managed Chrome browser in us-west-2 with dual interfaces
              </Text>
              <Text>
                <strong>DCV Stream:</strong> Low-latency video stream for human viewing (presigned URL, 5min TTL)
              </Text>
              <Text>
                <strong>CDP Automation:</strong> WebSocket connection for Playwright agent control
              </Text>
              <Text>
                <strong>Same Browser:</strong> DCV and CDP target the same browser instance - you see what the agent does
              </Text>
            </VStack>
          </CardBody>
        </Card>
      </Container>
    </Box>
  )
}