FROM node:20-alpine

RUN addgroup -S app && adduser -S app -G app

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

COPY src ./src

USER app

ENV NODE_ENV=production
EXPOSE 4000

CMD ["node", "src/server.js"]
