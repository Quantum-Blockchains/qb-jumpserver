#!/bin/bash

# Build QB Jump Server image
echo "Building QB Jump Server image..."
docker build -t qb-jumpserver:latest .

if [ $? -eq 0 ]; then
    echo "Image built successfully!"
    echo "Tagging image for Docker Hub..."
    docker tag qb-jumpserver:latest albertyablonskyi/qb-jumpserver:latest
    
    if [ $? -eq 0 ]; then
        echo "Image tagged successfully!"
        echo ""
        echo "Do you want to push to Docker Hub? (y/n)"
        read -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            echo "Pushing to Docker Hub..."
            docker push albertyablonskyi/qb-jumpserver:latest
            if [ $? -eq 0 ]; then
                echo "Successfully pushed to Docker Hub!"
            else
                echo "Failed to push to Docker Hub."
                exit 1
            fi
        else
            echo "Skipping Docker Hub push."
        fi
    else
        echo "Failed to tag image."
        exit 1
    fi
else
    echo "Failed to build image."
    exit 1
fi
