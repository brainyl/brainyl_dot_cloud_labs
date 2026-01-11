import type { Metadata } from 'next'
import { ChakraProvider } from '@chakra-ui/react'

export const metadata: Metadata = {
  title: 'AgentCore Browser Automation Demo',
  description: 'Watch AI agents work in real-time with AWS AgentCore',
}

export default function RootLayout({
  children,
}: {
  children: React.ReactNode
}) {
  return (
    <html lang="en">
      <head>
        {/* Load DCV SDK */}
        <script src="/dcv-sdk/dcvjs-umd/dcv.js"></script>
      </head>
      <body>
        <ChakraProvider>
          {children}
        </ChakraProvider>
      </body>
    </html>
  )
}
