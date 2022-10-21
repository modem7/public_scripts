#!/bin/bash

# Variables
PROJLOC="/mnt/folder/location" # Location of your Docker compose + env file

PS1='Choose an option: '
options=("Pull" "Start" "Stop" "Top" "List Running" "Logs" "Prune" "Quit")
echo ""
select opts in "${options[@]}"; do
    case $opts in
        "Pull")
            echo "Pulling images"
            if [ -d "$PROJLOC" ] 
              then
                docker compose --project-directory $PROJLOC pull
                exec $0
              else
               echo "Error: Directory $PROJLOC/ does not exist."
               break
            fi
            ;;
        "Start")
            echo "(Re)Creating and starting containers"
            docker compose --project-directory $PROJLOC up -d --remove-orphans
            exec $0
            break
            ;;
        "Stop")
            echo "Stopping and removing containers, images and volumes."
            docker compose --project-directory $PROJLOC down --rmi all -v
	        exec $0
            #break
            ;;
        "Top")
            echo "Displaying running processes."
            docker compose --project-directory $PROJLOC top
            exec $0
            ;;
        "List Running")
            echo "Displaying running containers."
            docker compose --project-directory $PROJLOC ps -a
            exec $0
            ;;
        "Logs")
            PS2='Choose an option: '
            # Create a list of files to display
            container_list=$(docker ps --format '{{.Names}}' | sort)
            echo -e "\nSelect which container you want to see logs for:\n"
            select container_name in ${container_list};
            do
              if [ -n "${container_name}" ]; then
              echo -e "\nYou've selected ${container_name}"
              fi
              break
              done
            docker logs --tail 50 ${container_name}
            exec $0
            ;;
        "Prune")
            echo "Clearing Docker cache."
            docker system prune -af --volumes
            exec $0
            ;;
	"Quit")
	    echo "Exiting script"
	    exit
	    ;;
        *) echo "invalid option $REPLY";;
    esac
done
