'use client'

import React from 'react'
import { useSearchParams, useRouter } from 'next/navigation'
import {
  Box,
  Container,
  VStack,
  Button,
  Text,
  Spinner,
  Alert,
  AlertIcon,
  useColorModeValue,
} from '@chakra-ui/react'
import { DCVViewer } from '../../components/DCVViewer'

export default function ViewerPage() {
  const searchParams = useSearchParams()
  const router = useRouter()
  const sessionId = searchParams.get('sessionId')
  const [liveViewUrl, setLiveViewUrl] = React.useState<string | null>(null)
  const [loading, setLoading] = React.useState(true)
  const [error, setError] = React.useState<string | null>(null)

  const bgColor = useColorModeValue('gray.50', 'gray.900')

  React.useEffect(() => {
    if (!sessionId) {
      setError('No session ID provided')
      setLoading(false)
      return
    }

    // Get live view URL
    const fetchLiveViewUrl = async () => {
      try {
        const response = await fetch(
          `http://localhost:8100/browser-session/v1/sessions/${sessionId}/live-view/presign`,
          {
            method: 'POST',
            headers: {
              'Content-Type': 'application/json',
              'X-Tenant-ID': 'demo',
              'X-User-ID': 'user1',
            },
            body: JSON.stringify({ ttl_seconds: 300 }),
          }
        )

        if (!response.ok) {
          const errorData = await response.json().catch(() => ({}))
          throw new Error(errorData.detail || `Failed to get live view: ${response.statusText}`)
        }

        const data = await response.json()
        setLiveViewUrl(data.presigned_url)
        setLoading(false)
      } catch (err: any) {
        setError(err.message || 'Failed to load live view')
        setLoading(false)
      }
    }

    fetchLiveViewUrl()
  }, [sessionId])

  if (loading) {
    return (
      <Box minH="100vh" bg={bgColor}>
        <VStack spacing={8} align="center" justify="center" minH="100vh">
          <Spinner size="xl" />
          <Text>Loading live view...</Text>
        </VStack>
      </Box>
    )
  }

  if (error) {
    return (
      <Box minH="100vh" bg={bgColor} py={12}>
        <Container maxW="4xl">
          <VStack spacing={6}>
            <Alert status="error">
              <AlertIcon />
              {error}
            </Alert>
            <Button onClick={() => router.back()}>
              Go Back
            </Button>
          </VStack>
        </Container>
      </Box>
    )
  }

  if (!liveViewUrl || !sessionId) {
    return (
      <Box minH="100vh" bg={bgColor} py={12}>
        <Container maxW="4xl">
          <Alert status="warning">
            <AlertIcon />
            Missing session information
          </Alert>
        </Container>
      </Box>
    )
  }

  return (
    <Box minH="100vh" bg={bgColor}>
      <VStack spacing={4} p={4}>
        <Alert status="info">
          <AlertIcon />
          <VStack align="start" spacing={1}>
            <Text fontWeight="bold">Live Browser View - Session: {sessionId}</Text>
            <Text fontSize="sm">Click directly in the browser to interact. Automation runs automatically via CDP.</Text>
          </VStack>
        </Alert>
      </VStack>
      <DCVViewer
        presignedUrl={liveViewUrl}
        sessionId={sessionId}
        runId={sessionId}
        onReleaseControl={async () => {
          console.log('Released control')
        }}
        onDisconnect={(reason) => {
          console.log('Disconnected:', reason)
        }}
      />
    </Box>
  )
}
