/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: false, // Disable to prevent double-rendering with DCV
  webpack: (config) => {
    config.resolve.alias.canvas = false
    return config
  },
  // DCV SDK worker file rewrites - map relative paths to actual SDK location
  async rewrites() {
    return [
      // DCV worker files from viewer pages
      {
        source: '/viewer/dcvjs/dcv/:path*',
        destination: '/dcv-sdk/dcvjs-umd/dcv/:path*',
      },
      {
        source: '/viewer/dcvjs/lib/:path*',
        destination: '/dcv-sdk/dcvjs-umd/lib/:path*',
      },
      // DCV worker files from root
      {
        source: '/dcvjs/dcv/:path*',
        destination: '/dcv-sdk/dcvjs-umd/dcv/:path*',
      },
      {
        source: '/dcvjs/lib/:path*',
        destination: '/dcv-sdk/dcvjs-umd/lib/:path*',
      },
    ];
  },
}

module.exports = nextConfig
