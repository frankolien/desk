FROM node:22-alpine
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY api ./api
COPY worker ./worker
COPY copyd ./copyd
ENV NODE_ENV=production
CMD ["node", "worker/index.mjs"]
